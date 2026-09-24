# Deployment notes for Squid on OpenWrt

Everything here was hit while getting `ssl_bump` working in the VM on
2026-09-25. All of it will bite again on real hardware.

## Squid runs as `nobody`

`cache_effective_user` is `nobody`, not `squid`. Both the log directory and
the certificate database must be owned by it, or Squid dies at startup with
`FATAL: Cannot open '/var/log/squid/access.log' for writing`:

```sh
mkdir -p /var/log/squid /var/cache/squid
chown -R nobody /var/log/squid /var/cache/squid
```

## `/var` is tmpfs, so the certificate database is wiped on every boot

`/var` is a symlink to `/tmp`. The `ssl_db` that `security_file_certgen`
creates under `/var/cache/squid` does not survive a reboot, and Squid will
not start without it. The setup script must recreate it at every boot:

```sh
mkdir -p /var/cache/squid
/usr/lib/squid/security_file_certgen -c -s /var/cache/squid/ssl_db -M 4MB
chown -R nobody /var/cache/squid
```

Either run this from an init script before Squid, or move `ssl_db` somewhere
persistent. Note the CA itself lives in `/etc/squid/ssl` and does persist.

## Stale shared memory blocks restarts

After an abnormal exit, Squid leaves segments behind and every restart fails
with `FATAL: Ipc::Mem::Segment::create failed to shm_open(...): (17) File
exists`, which procd turns into a crash loop. Clear them first:

```sh
rm -f /dev/shm/squid-*
```

## `peek all` silently disables bumping

See the comment in `squid.conf`. This is the single most costly mistake
available here, because nothing errors -- traffic just gets tunnelled and the
filter appears to do nothing.

## Diagnosing bump vs splice

`access.log` distinguishes them plainly:

- `TCP_TUNNEL/200 CONNECT www.google.com:443` -- spliced, not inspected.
- A `GET https://www.google.com/search?...` line -- bumped and inspected.

## The helper is called for CONNECT as well as GET

Squid hands the rewriter `host:port` (e.g. `www.google.com:443`), not a URL,
for CONNECT requests. The helper must leave those alone. `cases.tsv` covers
this.

## mbedTLS cannot parse a CA with critical name constraints

OpenWrt's `curl` is built against mbedTLS, which fails outright on a CA whose
`nameConstraints` extension is marked critical:

```
curl: (77) mbedTLS: error reading CA cert file: (-0x2562)
      X509 - The extension tag or value is invalid
```

Marking the extension non-critical makes it parse. The tradeoff is real:
critical means a client that does not understand constraints refuses the
certificate entirely, while non-critical means such a client silently ignores
the constraint -- which is the protection you wanted. This says nothing yet
about what phones and laptops do; it is an mbedTLS data point, and browsers
use different TLS stacks.
