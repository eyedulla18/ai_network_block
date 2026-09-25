# School AI Filter — Development Plan

Status: planning. No implementation yet.
Last updated: 2026-09-24

## Goal

A network-level filter for a rural Vanuatu secondary school's student Wi-Fi that:

1. Blocks AI chat sites and apps for students. Teachers keep unfiltered access on a
   separate network.
2. Keeps Google Search usable but removes AI Overviews and AI Mode.
3. Can be replicated by non-technical teachers at other schools.

## Constraints

- Uplink is Starlink. The router is reseller-managed, so **the design must not require
  changing the Starlink router**.
- ~30 unmanaged student devices at peak: school desktops, personal laptops, phones.
- Power is unreliable. Prefer low draw and storage that survives sudden loss.
- Hardware budget roughly US$60-150.
- Students depend on school Wi-Fi; cell coverage is poor, so hotspotting is not a
  significant bypass route.

## Target architecture

```
Starlink router  (teachers' Wi-Fi, unfiltered, untouched)
   | Ethernet
Filter box  (GL.iNet Brume 2 / GL-MT2500, OpenWrt)
   | Ethernet
TP-Link TL-WR841N v14  (access point mode, student Wi-Fi)
   |
Student devices
```

The TL-WR841N v14 has 4 MB flash / 32 MB RAM and no practical OpenWrt support. It is a
dumb access point only.

## Components

| Component | Role |
|---|---|
| AdGuard Home | DNS blocklist for AI sites; resolves `cert.school`; blocks known DoH providers |
| Squid (`ssl_bump`, intercept) | Peek at SNI; **bump Google search only**, splice everything else |
| URL rewrite helper (Lua) | Squid `url_rewrite_program`; canonicalizes Google `/search` URLs |
| Captive portal | Squid `external_acl_type` gate plus an auto-checking portal page (`portal/`) |
| Cert download page | `uhttpd` serving `http://cert.school/` |
| Firewall (fw4/nftables) | Student LAN only (see below) |

Firewall rules, student LAN only:

- Redirect TCP 80/443 to Squid.
- Drop UDP 443 (QUIC) so Chrome falls back to TCP HTTPS.
- Redirect all port 53 to AdGuard Home; drop TCP/UDP 853 (DoT).
- Mirror every rule on IPv6, or disable IPv6 on the student LAN entirely.

## Key design decisions

- **DNS alone cannot remove AI Overviews.** They are served from the same domain as
  normal search results, so HTTPS inspection is required.
- **Redirect, do not rewrite HTML.** `udm=14` selects Google's "Web" filter, which has
  no AI Overview. Far more robust than editing the page.
- **Bump only Google.** Lower CPU load, and a device without the CA installed loses only
  Google Search rather than the entire internet.
- **Unique CA per install**, generated on the device at first boot. The private key never
  leaves the device, never enters the repo, and is never shared between schools.
- **CA uses X.509 name constraints** limited to Google domains, so a leaked key cannot be
  used to impersonate other sites. *(Unverified: client support for name constraints on
  user-installed CAs.)*
- Do not buy hardware preconfigured by sellers. Install software from official sources.

## Verified facts

Checked 2026-09-24 against downloads.openwrt.org.

- Current OpenWrt stable: **25.12.5** (released 2026-06-30).
- **Target version: 25.12.x.** This uses the `apk` package manager, not `opkg`. 24.10 is
  the final opkg release. Setup scripts must be written against apk.
- Package availability, identical for `aarch64_generic` (VM) and `aarch64_cortex-a53`
  (Brume 2):

  | Package | 25.12.5 | 24.10.8 |
  |---|---|---|
  | squid | 7.1 | 7.1 |
  | adguardhome | 0.107.79 | 0.107.57 |
  | lua5.4 / luajit | yes | yes |
  | luci-app-squid | yes | yes |
  | **opennds** | **absent** | **absent** |

- **openNDS is not in the OpenWrt package feeds** for 23.05, 24.10 or 25.12. The only
  captive-portal packages remaining are `coova-chilli` and `wifidog`.
- **VirtualBox cannot be used.** The development machine is an Apple M2; VirtualBox does
  not run x86-64 guests on Apple Silicon. Replaced by QEMU with the OpenWrt
  `armsr/armv8` target, which runs natively on ARM via Apple's Hypervisor framework.
  Image: `openwrt-25.12.5-armsr-armv8-generic-ext4-combined-efi.img.gz`.

## Blocking unknown — RESOLVED 2026-09-24

**Is the OpenWrt Squid 7.1 package compiled with `--with-openssl` and `ssl_bump`?**

**Yes.** Verified in the QEMU VM on OpenWrt 25.12.5 armsr/armv8. `apk add squid` pulls in
`libopenssl3`, and `squid -v` reports:

```
'--with-openssl=/builder/.../target-aarch64_generic_musl/usr'
'--enable-ssl-crtd'
'--without-gnutls'
```

`--enable-ssl-crtd` means the dynamic certificate generator is included;
`/usr/lib/squid/security_file_certgen` is present in the package.

Proven further than the flags: a full interception config parses cleanly and loads the
CA. `squid -k parse` exits 0 on

```
https_port 3130 intercept ssl-bump generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB \
    tls-cert=/etc/squid/ssl/ca.crt tls-key=/etc/squid/ssl/ca.key
sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/cache/squid/ssl_db -M 4MB
acl gsearch ssl::server_name .google.com
ssl_bump peek all
ssl_bump bump gsearch
ssl_bump splice all
```

reporting `Loaded signing certificate: /CN=School Filter CA`.

A CA with X.509 name constraints also generates correctly on-device with the
`openssl-util` package, confirming the *generation* half of that design decision:

```
X509v3 Name Constraints: critical
    Permitted:
      DNS:.google.com
      DNS:.google.co.uk
```

Whether client devices *honor* those constraints on a user-installed CA remains open
(open question 5).

**No hardware fallback is needed. The design is viable on stock OpenWrt packages.**

## Development stages

### Stage 0 — URL rewriter (no VM required) — DONE 2026-09-24

Implemented in `rewriter/`. 51 cases pass, including every row of the observed-behavior
table below, plus loop-safety assertions on every rewrite. Runs on macOS with
`brew install lua@5.4`; no VM or hardware needed.

Two findings from building it:

- The `lua5.4` package installs **`/usr/bin/lua5.4`**, with no `/usr/bin/lua` symlink
  (confirmed from the package Makefile). The shebang must name it exactly.
- Host matching needs to be strict. A pattern permissive enough to accept `google.co.uk`
  also accepts `google.com.evil.example`; the first implementation had this bug and a
  test case now pins it.

**Language choice: Lua 5.4.** Squid runs the rewriter as a pool of long-lived child
processes (`url_rewrite_children`, commonly 20), so per-process memory is the binding
constraint on a 1 GB box already running Squid with TLS interception and AdGuard Home.
Lua is roughly 1 MB resident per process against roughly 10-15 MB for Python *(estimates;
measure at Stage 1)*. Disk is not the argument — the Brume 2 has 8 GB of eMMC and Python
would cost only about 3 MB. Python's standard library is also less of an advantage than
it appears: `urllib.parse.parse_qsl` discards blank values by default, which would
silently drop the `udm=` case, and neither language avoids hand-writing the parser.

`ucode`, OpenWrt's own language, ships in the base image and would cost nothing to
install, but cannot easily be run on macOS for local testing and almost no teacher would
recognize it. Worth revisiting only if memory proves tight.

The test cases live in a language-agnostic TSV so that the table -- the empirically
derived, hard-to-replace part -- survives a reimplementation in another language.

### Stage 1 — OpenWrt VM — DONE 2026-09-24

`brew install qemu`; boot `armsr/armv8` under QEMU with HVF acceleration. Automated by
`scripts/run-vm.sh`, which downloads the image, verifies it against OpenWrt's published
`sha256sums`, and boots it. Verified working on an Apple M2 with QEMU 11.1.1.

Note: the `armsr` image bridges `eth0` into `br-lan` with a static 192.168.1.1, so it has
no route out under QEMU user-mode networking until the LAN is switched to DHCP:

```
uci set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci commit network && /etc/init.d/network restart
```

**Decided 2026-09-24: QEMU from the command line, not UTM.** The VM is defined by a
committed shell script (`scripts/run-vm.sh`), which makes the environment reproducible by
anyone cloning the repo and doubles as documentation. UTM is a graphical wrapper around
the same engine, but stores its configuration in a `.utm` bundle that cannot be
version-controlled or reviewed. Two further reasons: OpenWrt has no graphical interface,
so UTM's VM window buys nothing; and Stage 2 needs a private link between two VMs
(`-netdev socket`), which is one flag on the command line but is not exposed by UTM's
network settings.

First task: run `squid -v` and settle the blocking unknown above.

### Stage 2a — explicit proxy, one VM — DONE 2026-09-25

Split out of Stage 2 so that failures are diagnosable: explicit-proxy mode has three
failure points rather than the six of full transparent interception.

**The whole chain works against live Google.** With `udm14.lua` installed at
`/usr/bin/udm14.lua` and the config in `squid/squid.conf`:

```
$ curl -i --proxy http://127.0.0.1:3128 --cacert ca.crt \
      'https://www.google.com/search?q=photosynthesis&udm=50&tbm=isch'
HTTP/1.1 200 Connection established
HTTP/1.1 302 Found
Location: https://www.google.com/search?q=photosynthesis&udm=14
```

Instagram through the same proxy returns 200 **without** the custom CA, confirming
spliced traffic is untouched.

**Open question 2 is half-answered.** `url_rewrite_extras "sfm=%{Sec-Fetch-Mode}>h"`
works; the header reaches the helper as `sfm=navigate`, or `sfm=-` when absent. The
design for background requests is therefore implementable. What is still unknown is what
Google's background requests actually look like -- `curl` fetches no subresources, so
that needs a real browser, not a VM.

Findings, all recorded in `squid/SETUP-NOTES.md`:

1. **The draft Squid config in this plan was wrong.** `ssl_bump peek all` matches again
   at step 2, and after peeking at step 2 Squid can only splice, so the bump rule is
   never reached. Every request was tunnelled (`TCP_TUNNEL/200` in `access.log`) and the
   filter silently did nothing. The fix is `acl step1 at_step SslBump1` plus
   `ssl_bump peek step1`. This is the most dangerous failure mode found so far because
   nothing errors.
2. Squid runs as `nobody`, not `squid`; the log dir and `ssl_db` need that ownership.
3. `/var` is a symlink to `/tmp` (tmpfs), so `ssl_db` is destroyed on every reboot and
   Squid will not start without it. The setup script must recreate it at boot.
4. Stale `/dev/shm/squid-*` segments turn any abnormal exit into a procd crash loop.
5. **Squid calls the rewriter for CONNECT as well as GET**, passing `host:port` rather
   than a URL. The helper must ignore those; `cases.tsv` now covers it.
6. **mbedTLS cannot parse a CA whose `nameConstraints` extension is critical** (error
   `-0x2562`). Non-critical parses fine. Relevant to open question 5, though it is an
   mbedTLS data point and browsers use other TLS stacks.

### Stage 2b — transparent interception, two VMs — DONE 2026-09-25

A client VM with **no proxy configuration at all** -- DHCP and a default gateway only --
has its traffic intercepted, Google decrypted, and `udm=50` rewritten to `udm=14`.
Instagram is spliced and works without the CA. See `TESTING.md` for how to reproduce.

Every rule verified by packet counter rather than by loading without error:

| Rule | Packets |
|---|---|
| `schoolfilter-http` (80 to Squid) | 1 |
| `schoolfilter-https` (443 to Squid) | 3 |
| `schoolfilter-dns` (53 to local resolver) | 5 |
| `schoolfilter-drop-quic` (UDP 443) | 3 |

A client without the CA gets `NONE_NONE/000 CONNECT` on Google and a TLS failure, which
is the expected un-certed student experience. `nslookup example.com 8.8.8.8` is answered
by the local resolver, so DNS cannot escape.

Findings:

1. **Firewall rules written to `/etc/nftables.d/` are silently inert.** fw4 only emits a
   `jump dstnat_lan` when a uci redirect exists for that zone, so a hand-written chain is
   created, appears in `nft list`, and never matches. Counter stays at 0 and every request
   bypasses the proxy with no error anywhere. Now built from named uci sections, and the
   script asserts the rules appear in the live ruleset.
2. **Squid died on every reboot.** `/var` is tmpfs, and the boot hook created
   `/var/cache/squid` but not `/var/log/squid`, so Squid failed with `Cannot open
   '/var/log/squid/access.log'`. Confirmed by rebooting twice: dead before the fix,
   running after, and still rewriting correctly. This is critical at a site with
   unreliable power.
3. busybox has no `install(1)`.
4. Packages must be installed *after* the network is configured; a fresh device has no
   route to any mirror.

### Stage 2c — real device (iPhone) — WORKING 2026-09-25

**The whole design works on a real iPhone.** Squid access log for the phone:

```
3 x TCP_REDIRECT/302    the rewriter firing on real searches
68 x TCP_MISS/200       Google decrypted and inspected
```

Facebook, Apple services and everything else spliced and untouched.

Two findings from the real device:

**1. A device without the CA loses Google Search and nothing else.** Before the
certificate was trusted, `www.google.com:443` logged 57 x `NONE_NONE/200` with
zero bytes -- the handshake aborted -- while `facebook.com`, `fbcdn.net`,
`gateway.icloud.com` all returned `TCP_TUNNEL/200` normally. This is exactly the
behaviour the design predicts, now confirmed rather than assumed.

**2. Open question 2 is answered: background requests are not a problem.**
Of 6 `/search` requests, 3 were rewritten and 3 passed through -- one redirect
plus one canonical fetch per search, which is the loop-safety property holding in
a real browser. Every background request went to a different path:

```
/gen_204 (48)   /xjs/_/js/... (34)   /complete/s (10)   /async/bgasy (3)
/client_204 (3) /pagead/1p-conversion/... (3)   /sgasync (1)   /recaptcha/... (4)
```

None are `/search`, so the rewriter leaves them alone and the page renders
correctly. The `Sec-Fetch-Mode` machinery is available if this ever changes, but
is not needed today.

*Caveat: Squid's `strip_query_terms` is on by default, so query strings are not
logged and the `udm` values of those requests could not be inspected.*

**Note on how it was reached.** Transparent interception via the gateway could not
be made to work with iOS on this setup: the phone ARPed for the gateway, received
the reply, and then sent no TCP at all -- DNS only. The explicit proxy path
(Configure Proxy > Manual, port 3128) worked immediately. Transparent
interception is verified in the two-VM lab, so this is an iOS-plus-bridged-VM
interaction rather than a flaw in the design; real hardware with its own wired
interfaces will not have it.

### Stage 2d — bridged setup notes (kept for reference)

`sudo ./scripts/run-vm.sh --bridged en0` puts the filter's LAN side on the real network so
a phone or laptop can use it as a gateway, with no extra hardware. Written and documented
in `TESTING.md` but **not yet run** -- it needs `sudo` and a device to configure by hand.

Set `LAN_DHCP=off` first. Two DHCP servers on one segment will break the home network.

This is the only environment that can answer the remaining client-side questions: whether
iOS and Android trust the CA, whether Android apps ignore it, whether name constraints are
honored, and what Google's background `/search` requests look like in a real browser.

### Stage 3 — certificate distribution and portal

Resolve the openNDS gap. Worth evaluating: a small nftables set plus a `uhttpd` CGI
script may be simpler and less fragile than adopting coova-chilli, given the modest
requirement (block unapproved MACs, serve a cert page, auto-verify, allow).

### Stage 4 — hardware

Only after Stages 0-3. Verify standard OpenWrt supports the GL-MT2500, or determine
whether GL.iNet's firmware (reportedly 21.02-based) ships a usable Squid. Test
performance with ~30 devices.

### Stage 5 — packaging

Idempotent setup script (POSIX sh for BusyBox ash) driven by one settings file, or an
Image Builder firmware with an `/etc/uci-defaults` first-boot script that generates the
CA. Publish via GitHub releases with checksums, plus a teacher guide with screenshots.

## URL rewrite specification

Applies to Google search hosts, path `/search`.

1. Split the query string on `&`; split each pair at the first `=`; percent-decode both
   name and value; `+` becomes a space in values.
2. Collect `q`, `start` (only if all digits), and all `udm` values in order. Ignore
   everything else, including `tbm`, uppercase `UDM`, and tracking parameters.
3. `mode` = the last `udm` if it is in ALLOW, otherwise `14`.
   ALLOW (initial): 2, 7, 12, 14, 18, 28, 36. Never 50.
4. **PASS** if the decoded parameters are exactly `q`, an optional numeric `start`, and
   exactly one `udm` in ALLOW — nothing else.
5. Otherwise **302** to
   `https://<same host>/search?q=<encoded q>&udm=<mode>[&start=<n>]`.
6. No loops: the rebuilt URL must itself pass. Compare decoded parameters, never raw
   strings.

Helper protocol: reply `OK status=302 url=<new>` to redirect, `ERR` to leave unchanged.

## Observed Google behavior

Tested 2026-09-24. One query ("how does photosynthesis work"), signed-in Chrome, from
Vanuatu. Undocumented behavior; Google may change it at any time. Re-verify in the VM.

| URL suffix | Result |
|---|---|
| (none) | All tab, AI Overview |
| `udm=14` | Web, no AI Overview |
| `udm=14&udm=50` | AI Mode |
| `udm=50&udm=14` | Web |
| `udm=2&udm=50` | AI Mode |
| `udm=50&udm=2` | Images |
| `udm=14&udm=2` | Images |
| `udm=abc` / `udm=` | All, AI Overview |
| `udm=14&udm=abc` | All, AI Overview |
| `tbm=isch&udm=50` | All, AI Overview |
| `udm=14&tbm=isch` | All, AI Overview |
| `udm=14&%75dm=50` | AI Mode (encoded name is decoded) |
| `udm=14&udm=%35%30` | AI Mode (encoded value is decoded) |
| `UDM=50` | Ignored, so All tab with AI Overview |

Takeaways: the last `udm` wins; an invalid or empty last value falls back to All with an
AI Overview; any `tbm` alongside `udm` returns All with an AI Overview; Google
percent-decodes both names and values; parameter names are case-sensitive.

## DNS blocklist (starting point)

Verify against AdGuard Home query logs.

- **Google Gemini**: `gemini.google.com`, `gemini.google`, `bard.google.com`,
  `aistudio.google.com`, `ai.studio`, `notebooklm.google.com`, `notebooklm.google`,
  `labs.google`, `generativelanguage.googleapis.com`
- **Microsoft Copilot**: `copilot.microsoft.com`, `copilot.cloud.microsoft`
  (Copilot via `bing.com/chat` cannot be blocked by DNS)
- **Others**: `chatgpt.com`, `openai.com`, `claude.ai`, `duck.ai`, `perplexity.ai`,
  `meta.ai`, `grok.com`, `deepseek.com`
- **Bypass routes**: `translate.goog` (Google Translate acts as a web proxy)

Never block `google.com` or `googleapis.com` wholesale — it breaks Gmail, YouTube and
sign-in. Blocking a parent domain usually blocks its subdomains; use allowlist entries
for exceptions such as `noai.duckduckgo.com`.

The blocklist is hosted in this repo so AdGuard Home can subscribe to it and every
school receives updates.

**Implemented 2026-09-25** as `blocklists/ai-sites.txt` (30 domains) plus
`blocklists/allowlist.txt`. `scripts/setup-filter.sh` turns these into dnsmasq rules;
the same file works unchanged as an AdGuard Home subscription URL. AdGuard Home itself is
not yet installed -- dnsmasq already receives all DNS via the port-53 redirect, so it does
the blocking today with no extra moving parts. AdGuard Home remains the better answer for
a query log and a teacher-facing UI.

Verified from a client: `chatgpt.com`, `claude.ai`, `gemini.google.com` and
`perplexity.ai` resolve to `0.0.0.0`, while `www.google.com`, `google.com`,
`www.youtube.com` and `accounts.google.com` are untouched.

Two ways a blocklist can appear to work while doing nothing, both now handled:

- OpenWrt points dnsmasq's `conf-dir` at a generated path under `/tmp`, so files placed in
  `/etc/dnsmasq.d` are ignored entirely. `confdir` has to be repointed via uci.
- `address=/domain/0.0.0.0` answers only A queries. AAAA goes upstream, so a dual-stack
  client still reaches the site over IPv6. Every entry needs both an A and an AAAA rule.

## Certificate distribution

- Generate with `openssl` on the device: 10-year CA, CN "School Filter CA".
- Serve `school-ca.crt` as `application/x-x509-ca-cert` and `school-ca.mobileconfig` as
  `application/x-apple-aspen-config`.
- The page detects the OS and shows only the relevant steps. iOS additionally requires
  Settings > General > About > Certificate Trust Settings.
- The captive-portal popup browser, especially on iOS, may block downloads. The page must
  tell users to open it in Safari or Chrome.
- Auto-check: the portal page loads a small resource from bumped `www.google.com`. If it
  loads, the certificate works and the device is approved.
- MAC randomization means devices reappear at the portal; the auto-check keeps that to a
  quick pass.
- Support: QR codes on classroom walls, visual guides in English and Bislama, trained
  student helpers.

## Known limitations

- Android apps, including the Google app, ignore user-installed CAs and will fail on
  bumped domains.
- Devices without the certificate cannot use Google Search at all (HSTS, no click-through).
- Firefox uses its own certificate store.
- `udm` is undocumented and Google can change its behavior without notice.
- Privacy: only Google Search is inspected. Keep logging minimal and obtain school and
  parent consent.

## Bypass threats and mitigations

| Threat | Mitigation |
|---|---|
| Other Google country domains (`google.co.uk`) | Bump all `google.*` search domains, or DNS-block non-`.com` |
| Background requests to AI Mode | Block decoded `udm=50` in every request; review logs |
| VPN apps and web proxies | DNS blocklists for VPN/proxy domains; block common VPN ports. Not airtight |
| `*.translate.goog` proxy | DNS block |
| IPv6 / QUIC leaks | Mirror rules on IPv6 or disable it; drop UDP 443 |
| ECH hiding SNI | Google does not use it yet. Strip HTTPS/SVCB DNS records if needed |
| New AI Mode shortcuts | Periodic log review |
| Gemini in Chrome, Lens | DNS blocks where possible |
| **Starlink Wi-Fi password leaks** | Reseller changes it; teachers only. This is the weak point of the whole design |

## Conventions

- Shell scripts: POSIX sh, compatible with OpenWrt BusyBox ash.
- URL helper in Lua. *(Confirm which interpreter is present on the target: the feed
  offers `lua5.4` and `luajit`.)*
- Never commit private keys or generated certificates.
- Every script must be safe to re-run.
- Unit-test the URL rewrite logic against a table of cases including every row of the
  observed-behavior table.
- Flag unverified assumptions. Check configuration syntax against the installed versions
  of Squid, AdGuard Home and the portal software, not against documentation for other
  versions.

## Open questions

1. Bump versus DNS-block for non-`.com` Google domains.
2. **Background requests.** Google's page fetches `/search` with many parameters;
   stripping them breaks the page. Current plan: full canonicalization only when
   `Sec-Fetch-Mode: navigate`, and block decoded `udm=50` on all requests. Squid's
   `url_rewrite_extras` can pass `%{Sec-Fetch-Mode}>h` to the helper, which makes this
   workable — *verify against the Squid build on the target.* Find other AI endpoints via
   Squid logs.
3. ~~**What replaces openNDS?**~~ **Answered 2026-09-25: none of them.** The gating is
   done in Squid, which already sees every web request, so no captive-portal daemon is
   needed. An `external_acl_type` helper checks the client against an approvals file on
   every request, `deny_info` sends unapproved devices to the portal, and the walled
   garden is two `http_access allow` lines. The portal page proves the CA is installed by
   fetching from bumped Google and then calls a CGI that approves the device. Verified
   end to end: unapproved gets 302 to the portal, the CGI approves, access opens without
   a restart, and search is still rewritten. See `portal/README.md`.
4. Block `duckduckgo.com` (it serves AI answers) and allow only `noai.duckduckgo.com`?
5. Do student devices honor X.509 name constraints on user-installed CAs?
6. Which other endpoints serve AI Overviews or AI Mode?
7. Parameters worth preserving later, each tested to confirm it does not reintroduce AI
   Overviews: `tbs`, `hl`, `safe`.
