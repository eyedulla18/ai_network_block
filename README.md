# School AI Filter

A network-level filter for a school's student Wi-Fi. It blocks AI chat sites and
strips Google's AI Overviews and AI Mode, while leaving ordinary search — and the
rest of the internet — working normally.

Built for a rural secondary school in Vanuatu on a Starlink connection, and
meant to be replicable by a teacher at another school without a networking
background.

**Status: working in a test environment. Not yet deployed on hardware.**
Google AI Overviews and AI Mode are removed, 30 AI domains are DNS-blocked, and
all of it survives a reboot. See [PLAN.md](PLAN.md) for exactly what is proven
and what is still open.

## How it works

Two problems, two different answers.

**AI chat sites** (ChatGPT, Claude, Gemini, Copilot) live on their own domains, so
DNS blocking is enough. That is [`blocklists/ai-sites.txt`](blocklists/ai-sites.txt).

**Google AI Overviews** cannot be blocked that way — they are served from the same
domain as normal search results. So the filter inspects Google search traffic only,
and rewrites the URL:

```
https://www.google.com/search?q=photosynthesis          →  302 redirect
https://www.google.com/search?q=photosynthesis&udm=14
```

`udm=14` selects Google's "Web" tab, which has no AI Overview. Redirecting rather
than editing the page means nothing breaks when Google changes its HTML.

To read an HTTPS URL the filter has to decrypt the connection, which needs a
certificate installed on each student device. It decrypts **Google search only** —
everything else is passed through untouched. A device without the certificate
loses Google Search, not the whole internet.

```
Starlink router ── teachers' Wi-Fi (unfiltered, untouched)
       │
   filter box ── OpenWrt + Squid + AdGuard/dnsmasq
       │
  access point ── student Wi-Fi
```

## Repository layout

| Path | What it is |
|---|---|
| [`PLAN.md`](PLAN.md) | The design, what is verified, and every open question |
| [`TESTING.md`](TESTING.md) | How to run the whole thing in VMs, or against real devices |
| `rewriter/` | The URL canonicalizer and its 54-case test suite |
| `squid/` | Verified Squid config and hard-won deployment notes |
| `blocklists/` | Blocked domains, and exceptions |
| `scripts/setup-filter.sh` | Idempotent device setup — the whole install |
| `scripts/run-vm.sh` | Boots a test filter VM on an Apple Silicon Mac |
| `scripts/run-client-vm.sh` | Boots a client VM behind the filter |

## Try it without any hardware

You need a Mac with Apple Silicon and `brew install qemu`.

```sh
./scripts/run-vm.sh          # filter VM
./scripts/run-client-vm.sh   # client VM, in a second terminal
```

Then follow [TESTING.md](TESTING.md). The rewriter's test suite needs nothing at
all beyond `brew install lua@5.4`:

```sh
lua5.4 rewriter/run-tests.lua
# 54 cases, 30 loop checks, 0 failed
```

## What this cannot do

- **Android apps ignore user-installed certificates**, including the Google app.
  They will fail on Google search rather than filtering it.
- **Firefox has its own certificate store** and needs separate configuration.
- **A student who learns the teachers' Wi-Fi password bypasses everything.** That
  is the weak point of the whole design, and it is social, not technical.
- **`udm` is undocumented.** Google can change this behaviour at any time.
- Web proxies and VPNs are only partly addressable by DNS blocking.

## Privacy

The filter decrypts Google search traffic and nothing else. Logging is minimal
and the access log lives on tmpfs, so it does not survive a reboot. Any real
deployment needs school and parent consent first.

## Licence

Not yet chosen.
