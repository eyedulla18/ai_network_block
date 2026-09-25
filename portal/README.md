# Captive portal

Gates the student LAN: a device cannot browse until it has proved the school
CA is installed. The proof is automatic -- nobody types a password.

openNDS, which the original design named, is absent from the OpenWrt package
feeds for 23.05, 24.10 and 25.12. Rather than adopt coova-chilli or wifidog,
this does the gating in Squid, which already sees every web request.

## How it works

```
unapproved device
   │  any http request
   ▼
 Squid   http_access deny  →  deny_info 302 http://cert.school:8080/
   │
   ▼
 portal page
   │  fetch https://www.google.com/generate_204
   │  (Google is the one domain this network decrypts, so this
   │   succeeds only if the CA is installed and trusted)
   ▼
 /cgi-bin/approve   →  appends the client IP to approved.txt
   │
   ▼
 full access, no restart needed
```

The walled garden is two lines of Squid config: the portal host, and Google
search. Google has to be reachable *before* approval, because fetching from it
is the test.

| File | Role |
|---|---|
| `sf-approved.sh` | Squid `external_acl_type` helper; reads `approved.txt` per request |
| `cgi-bin/approve` | Adds the caller's IP to `approved.txt` |
| `../certpage/index.html` | Runs the check and calls the CGI |

## Notes

**The helper must read only the first field.** Squid appends the ACL's own
arguments as a final field, sending `-` when there are none, so a request for
`192.168.0.50` arrives as `192.168.0.50 -`. Comparing the whole line never
matches, and the symptom is a device that is approved but still gated.

**No restart is needed to approve a device.** `external_acl_type` consults the
file on every lookup, cached for `ttl=30` / `negative_ttl=5`. A `deny_info`
approach with a static `acl ... "file"` would have needed `squid -k reconfigure`
from a CGI, and therefore privileges the web server should not have.

**Behind an explicit proxy, the web server sees the proxy, not the device.**
uhttpd forwards only a three-header whitelist to CGI (`ACCEPT`, `HOST`,
`USER_AGENT`), so `X-Forwarded-For` never arrives and `REMOTE_ADDR` is the
router. Left alone, the portal would approve the router and cheerfully report
success while the device stayed gated. Squid knows the real client, so the URL
rewriter stamps `?ip=` onto the approve URL, which reaches CGI as
`QUERY_STRING`. The CGI trusts that only when the request came from the proxy
address. The rewriter skips a URL that already carries the correct stamp, or
the redirect target would match again and loop.

**Approval is by IP, not MAC.** Squid sees the client address, not its hardware
address. Devices with MAC randomization will reappear at the portal after a
lease change; the automatic check makes that a single tap rather than a
re-enrolment.

**Spliced HTTPS cannot be redirected.** An unapproved device asking for a
non-Google HTTPS site gets a refused connection rather than the portal, because
Squid is not decrypting that traffic and has nothing to inject. Any plain HTTP
request then brings up the portal. This is how most captive portals behave.

## Turning it off

```sh
echo 'PORTAL=off' >> /etc/school-filter.conf
sh scripts/setup-filter.sh
```
