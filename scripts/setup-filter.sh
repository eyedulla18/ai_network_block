#!/bin/sh
#
# Idempotent setup for the School AI Filter, run ON the OpenWrt device.
#
#   ./scripts/setup-filter.sh
#
# Safe to re-run: every step checks before acting. Nothing here is specific to
# one school; per-site values come from /etc/school-filter.conf (created on
# first run) or the environment.
#
# Targets OpenWrt 25.12.x, which uses apk rather than opkg.
#
set -eu

CONF=/etc/school-filter.conf
[ -f "$CONF" ] && . "$CONF"

WAN_IF=${WAN_IF:-eth0}
LAN_IF=${LAN_IF:-eth1}
LAN_ADDR=${LAN_ADDR:-192.168.1.1}
LAN_MASK=${LAN_MASK:-255.255.255.0}
LAN_CIDR=${LAN_CIDR:-192.168.1.0/24}

# "server" runs DHCP on the student LAN (normal deployment). Use "off" when the
# LAN side is bridged onto a network that already has a DHCP server, such as a
# home router during testing -- two DHCP servers on one segment hand out
# conflicting leases and break the network for everyone on it.
LAN_DHCP=${LAN_DHCP:-server}

# Port for the certificate download page. Deliberately not 80: the firewall
# redirects LAN port 80 into Squid, so a page served there would be proxied
# rather than delivered.
CERT_PORT=${CERT_PORT:-8080}

# OpenWrt's squid init script always appends one "http_port" from uci, so there
# is a forward-proxy port whether you want one or not. Giving it ssl-bump
# options turns it into a useful fallback: a device can be pointed at it
# explicitly when transparent interception is not available.
EXPLICIT_PROXY_PORT=${EXPLICIT_PROXY_PORT:-3128}

# Captive portal. "on" means a device cannot browse until it has proved the
# school CA is installed, which the portal page checks automatically. Set to
# "off" to let every device on the student LAN straight through.
PORTAL=${PORTAL:-on}
PORTAL_HOST=${PORTAL_HOST:-cert.school}
APPROVED_FILE=${APPROVED_FILE:-/etc/school-filter/approved.txt}
WWW=${WWW:-/etc/school-filter/www}

HTTP_PORT=${HTTP_PORT:-3129}
HTTPS_PORT=${HTTPS_PORT:-3130}
CA_DIR=${CA_DIR:-/etc/squid/ssl}
CA_CN=${CA_CN:-School Filter CA}
CA_DAYS=${CA_DAYS:-3650}
SSL_DB=${SSL_DB:-/var/cache/squid/ssl_db}
SSL_DB_SIZE=${SSL_DB_SIZE:-4MB}

# Marked non-critical deliberately. mbedTLS refuses to parse a CA whose
# nameConstraints extension is critical (error -0x2562), which breaks clients
# built against it. See squid/SETUP-NOTES.md for the tradeoff.
CA_NAME_CONSTRAINTS=${CA_NAME_CONSTRAINTS:-permitted;DNS:.google.com}

SQUID_USER=nobody   # OpenWrt's cache_effective_user, NOT "squid"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
skip() { printf '    (already done) %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

###########################################################################
say "Writing $CONF"
###########################################################################
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# School AI Filter settings. Edit, then re-run scripts/setup-filter.sh.
WAN_IF=$WAN_IF
LAN_IF=$LAN_IF
LAN_ADDR=$LAN_ADDR
LAN_MASK=$LAN_MASK
LAN_CIDR=$LAN_CIDR
LAN_DHCP=$LAN_DHCP
EOF
else
  skip "$CONF exists"
fi

###########################################################################
say "Configuring interfaces ($WAN_IF = WAN, $LAN_IF = LAN)"
###########################################################################
# The armsr image bridges eth0 into br-lan with a static address, which leaves
# the box with no route out. Put WAN on its own interface and give LAN the
# second NIC.
if [ "$(uci -q get network.wan.device || true)" != "$WAN_IF" ]; then
  uci set network.wan=interface
  uci set network.wan.device="$WAN_IF"
  uci set network.wan.proto='dhcp'
  uci commit network
  NET_DIRTY=1
else
  skip "wan on $WAN_IF"
fi

# The armsr image ships network.wan6 bound to eth1 -- the very interface this
# script repurposes as the student LAN. Reassigning only network.wan leaves
# wan6 there, which puts the student LAN in the WAN firewall zone (it appears in
# input_wan and forward_wan) and, worse, adds it to srcnat_wan so traffic
# heading back to students is masqueraded. Nothing errors; the rules just behave
# strangely. Point wan6 at the real WAN.
if [ -n "$(uci -q get network.wan6 || true)" ] \
   && [ "$(uci -q get network.wan6.device || true)" != "$WAN_IF" ]; then
  uci set network.wan6.device="$WAN_IF"
  uci commit network
  NET_DIRTY=1
else
  skip "wan6 not on the lan device"
fi

if [ "$(uci -q get network.lan.ipaddr || true)" != "$LAN_ADDR" ] \
   || [ "$(uci -q get network.lan.device || true)" != "$LAN_IF" ]; then
  uci set network.lan=interface
  uci set network.lan.device="$LAN_IF"
  uci set network.lan.proto='static'
  uci set network.lan.ipaddr="$LAN_ADDR"
  uci set network.lan.netmask="$LAN_MASK"
  uci -q delete network.lan.ports || true
  uci commit network
  NET_DIRTY=1
else
  skip "lan on $LAN_IF at $LAN_ADDR"
fi

if [ "$LAN_DHCP" = off ]; then
  if [ "$(uci -q get dhcp.lan.ignore || true)" != "1" ]; then
    uci set dhcp.lan.ignore='1'; uci commit dhcp; NET_DIRTY=1
  else skip "DHCP server disabled on lan"; fi
else
  if [ -n "$(uci -q get dhcp.lan.ignore || true)" ]; then
    uci -q delete dhcp.lan.ignore; uci commit dhcp; NET_DIRTY=1
  else skip "DHCP server enabled on lan"; fi
fi

# IPv6 off on the student LAN. Mirroring every rule onto IPv6 is more surface
# than this deployment needs, and a leak there bypasses the whole filter.
if [ "$(uci -q get dhcp.lan.dhcpv6 || true)" != "disabled" ]; then
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ra='disabled'
  uci -q delete network.lan.ip6assign || true
  uci commit dhcp; uci commit network
  NET_DIRTY=1
else
  skip "IPv6 disabled on lan"
fi

if [ "${NET_DIRTY:-0}" = 1 ]; then
  say "Restarting network"
  /etc/init.d/network restart
  sleep 5
fi

###########################################################################
say "Installing packages"
###########################################################################
apk update >/dev/null 2>&1 || true
for p in squid lua5.4 openssl-util; do
  if apk info -e "$p" >/dev/null 2>&1; then skip "$p"; else apk add "$p"; fi
done

###########################################################################
say "Generating CA (if absent)"
###########################################################################
mkdir -p "$CA_DIR"
if [ ! -f "$CA_DIR/ca.crt" ]; then
  openssl req -new -newkey rsa:2048 -sha256 -days "$CA_DAYS" -nodes -x509 \
    -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" \
    -subj "/CN=$CA_CN" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "nameConstraints=$CA_NAME_CONSTRAINTS" >/dev/null 2>&1
  chmod 600 "$CA_DIR/ca.key"
  chmod 644 "$CA_DIR/ca.crt"
  say "CA created. Fingerprint:"
  openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256
else
  skip "CA exists at $CA_DIR/ca.crt"
fi

###########################################################################
say "Installing URL rewriter"
###########################################################################
if [ -f "$SRC/rewriter/udm14.lua" ]; then
  # busybox has no install(1)
  cp "$SRC/rewriter/udm14.lua" /usr/bin/udm14.lua
  chmod 755 /usr/bin/udm14.lua
  [ -s /usr/bin/udm14.lua ] || { echo "udm14.lua copied as an empty file" >&2; exit 1; }
  echo 'https://www.google.com/search?q=selftest&udm=50' | /usr/bin/udm14.lua \
    | grep -q 'udm=14' && printf '    rewriter self-test OK\n' \
    || { echo "rewriter self-test FAILED" >&2; exit 1; }
else
  echo "rewriter/udm14.lua not found next to this script" >&2; exit 1
fi

###########################################################################
say "Installing ssl_db boot hook"
###########################################################################
# /var is a symlink to /tmp (tmpfs), so the certificate database is destroyed
# on every reboot and Squid refuses to start without it. Rebuild it at boot,
# before Squid. Also clears stale shared memory, which otherwise turns any
# abnormal exit into a procd crash loop.
cat > /etc/init.d/school-filter-ssldb <<'INIT'
#!/bin/sh /etc/rc.common
# Rebuilds Squid's TLS certificate database, which lives on tmpfs.
START=49
start() {
    . /etc/school-filter.conf 2>/dev/null || true
    SSL_DB=${SSL_DB:-/var/cache/squid/ssl_db}
    SSL_DB_SIZE=${SSL_DB_SIZE:-4MB}
    rm -f /dev/shm/squid-*

    # BOTH of these live under /var, which is a symlink to tmpfs. They are
    # gone after every reboot, and Squid refuses to start without either one:
    #   no log dir  -> FATAL: Cannot open '/var/log/squid/access.log'
    #   no ssl_db   -> the certificate generator cannot start
    # The school this is built for has unreliable power, so this hook is what
    # stands between a power cut and a filter that never comes back.
    mkdir -p "$(dirname "$SSL_DB")" /var/log/squid

    if [ ! -d "$SSL_DB" ]; then
        /usr/lib/squid/security_file_certgen -c -s "$SSL_DB" -M "$SSL_DB_SIZE" >/dev/null 2>&1
    fi
    chown -R nobody "$(dirname "$SSL_DB")" /var/log/squid 2>/dev/null || true
}
INIT
chmod 755 /etc/init.d/school-filter-ssldb
/etc/init.d/school-filter-ssldb enable 2>/dev/null || true
mkdir -p /var/log/squid
/etc/init.d/school-filter-ssldb start

###########################################################################
say "Installing captive portal ($PORTAL)"
###########################################################################
mkdir -p "$(dirname "$APPROVED_FILE")" "$WWW/cgi-bin"
touch "$APPROVED_FILE"
chmod 644 "$APPROVED_FILE"

if [ -d "$SRC/portal" ]; then
  cp "$SRC/portal/sf-approved.sh" /usr/bin/sf-approved.sh
  chmod 755 /usr/bin/sf-approved.sh
  [ -s /usr/bin/sf-approved.sh ] || { echo "sf-approved.sh copied empty" >&2; exit 1; }
  cp "$SRC/portal/cgi-bin/approve" "$WWW/cgi-bin/approve"
  chmod 755 "$WWW/cgi-bin/approve"
  [ -s "$WWW/cgi-bin/approve" ] || { echo "approve CGI copied empty" >&2; exit 1; }
else
  echo "portal/ not found next to this script" >&2; exit 1
fi

# The portal has to be reachable by name before a device is approved, so point
# it at the router in DNS.
printf 'address=/%s/%s\n' "$PORTAL_HOST" "$LAN_ADDR" > /etc/dnsmasq.d/20-school-filter-portal.conf
/etc/init.d/dnsmasq restart >/dev/null 2>&1
sleep 2

# Build the Squid access block. With the portal on, an unapproved device may
# reach only the portal itself and Google search -- the latter because fetching
# from bumped Google is how the portal proves the certificate is trusted.
if [ "$PORTAL" = on ]; then
  SQUID_PORTAL_CONF=$(cat <<EOF
# Checked per request against $APPROVED_FILE, with no restart needed.
# negative_ttl is deliberately short: it is how long a device keeps being
# refused after the portal has approved it. Measured at 5s, apps stayed broken
# for about 11 seconds after approval once retry backoff was included. The
# helper is a few lines of shell reading a tiny file, so frequent lookups cost
# nothing at this scale.
external_acl_type sf_approved ttl=60 negative_ttl=1 children-max=5 %SRC /usr/bin/sf-approved.sh
acl approved external sf_approved
acl portalhost dstdomain $PORTAL_HOST

http_access deny !studentlan
http_access allow approved
http_access allow portalhost
http_access allow gsearch
http_access deny all

# Anything denied above is a device that has not proved it has the certificate.
# Send it to the portal rather than showing a proxy error.
deny_info 302:http://$PORTAL_HOST:$CERT_PORT/ all
EOF
)
else
  SQUID_PORTAL_CONF=$(cat <<EOF
http_access allow studentlan
http_access deny all
EOF
)
fi

###########################################################################
say "Writing squid.conf (intercept mode)"
###########################################################################
cat > /etc/squid/squid.conf <<EOF
# Generated by scripts/setup-filter.sh -- edits will be overwritten.

http_port $HTTP_PORT intercept
https_port $HTTPS_PORT intercept ssl-bump \\
    generate-host-certificates=on dynamic_cert_mem_cache_size=4MB \\
    tls-cert=$CA_DIR/ca.crt tls-key=$CA_DIR/ca.key

sslcrtd_program /usr/lib/squid/security_file_certgen -s $SSL_DB -M $SSL_DB_SIZE
sslcrtd_children 4

# Bump ONLY the Google search hosts, never all of *.google.com.
#
# ".google.com" also matches play.google.com, accounts.google.com and the
# clients6.google.com API hosts. Those are used by apps that pin certificates,
# which reject the intercepted connection outright: measured on a real iPhone,
# play.google.com made 21 connections and completed zero requests, retrying in a
# loop, while www.google.com completed 154. Bumping them breaks Google Play and
# app sign-in for no benefit, since only search carries AI Overviews.
#
# Matches google.<tld> and www.google.<tld>, including two-part suffixes such as
# google.co.uk, and nothing deeper.
acl gsearch ssl::server_name_regex -i ^(www\\.)?google\\.[a-z]{2,}(\\.[a-z]{2,})?$

# peek MUST be restricted to step 1. "ssl_bump peek all" matches again at
# step 2, and after peeking at step 2 Squid can only splice -- so the bump
# rule is never reached and every connection is tunnelled, with no error
# logged anywhere. Verified the hard way; see squid/SETUP-NOTES.md.
acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump bump gsearch
ssl_bump splice all

url_rewrite_program /usr/bin/udm14.lua
url_rewrite_children 5 startup=1 idle=1 concurrency=0
url_rewrite_extras "sfm=%{Sec-Fetch-Mode}>h rm=%>rm ip=%>a"

acl studentlan src $LAN_CIDR
$SQUID_PORTAL_CONF

cache deny all
access_log /var/log/squid/access.log squid
EOF

squid -k parse >/dev/null 2>&1 || { echo "squid.conf failed to parse" >&2; squid -k parse; exit 1; }
printf '    squid.conf parses clean\n'

###########################################################################
say "Installing firewall rules"
###########################################################################
# Use uci firewall sections, NOT hand-written files in /etc/nftables.d.
#
# A chain declared in an include file is created but never jumped to: fw4 only
# emits "jump dstnat_lan" when a uci redirect exists for that zone. The rules
# load without error, show up in "nft list chain", and silently never match --
# counter stays at 0 and every request bypasses the proxy. Verified the hard
# way. Named uci sections also make this idempotent by construction.
rm -f /etc/nftables.d/10-school-filter.nft

# Student web traffic to Squid.
uci -q delete firewall.sf_http || true
uci set firewall.sf_http=redirect
uci set firewall.sf_http.name='schoolfilter-http'
uci set firewall.sf_http.src='lan'
uci set firewall.sf_http.proto='tcp'
uci set firewall.sf_http.src_dport="80"
uci set firewall.sf_http.dest_port="$HTTP_PORT"
uci set firewall.sf_http.target='DNAT'

uci -q delete firewall.sf_https || true
uci set firewall.sf_https=redirect
uci set firewall.sf_https.name='schoolfilter-https'
uci set firewall.sf_https.src='lan'
uci set firewall.sf_https.proto='tcp'
uci set firewall.sf_https.src_dport="443"
uci set firewall.sf_https.dest_port="$HTTPS_PORT"
uci set firewall.sf_https.target='DNAT'

# Force all DNS through the local resolver.
uci -q delete firewall.sf_dns || true
uci set firewall.sf_dns=redirect
uci set firewall.sf_dns.name='schoolfilter-dns'
uci set firewall.sf_dns.src='lan'
uci add_list firewall.sf_dns.proto='tcp'
uci add_list firewall.sf_dns.proto='udp'
uci set firewall.sf_dns.src_dport="53"
uci set firewall.sf_dns.dest_port="53"
uci set firewall.sf_dns.target='DNAT'

# Drop QUIC so browsers fall back to TCP, which Squid can intercept.
uci -q delete firewall.sf_quic || true
uci set firewall.sf_quic=rule
uci set firewall.sf_quic.name='schoolfilter-drop-quic'
uci set firewall.sf_quic.src='lan'
uci set firewall.sf_quic.dest='*'
uci set firewall.sf_quic.proto='udp'
uci set firewall.sf_quic.dest_port="443"
uci set firewall.sf_quic.target='DROP'

# Drop DNS-over-TLS so it cannot escape the local resolver.
uci -q delete firewall.sf_dot || true
uci set firewall.sf_dot=rule
uci set firewall.sf_dot.name='schoolfilter-drop-dot'
uci set firewall.sf_dot.src='lan'
uci set firewall.sf_dot.dest='*'
uci add_list firewall.sf_dot.proto='tcp'
uci add_list firewall.sf_dot.proto='udp'
uci set firewall.sf_dot.dest_port="853"
uci set firewall.sf_dot.target='DROP'

uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1 || {
  echo "firewall restart failed" >&2; exit 1; }

# Prove the rules are actually reachable, rather than trusting that they loaded.
if nft list table inet fw4 2>/dev/null | grep -q "redirect to :$HTTPS_PORT"; then
  printf '    firewall rules loaded and wired into fw4\n'
else
  echo "firewall rules did not appear in the fw4 ruleset" >&2; exit 1
fi

###########################################################################
say "Installing DNS blocklist"
###########################################################################
BLOCKLIST=${BLOCKLIST:-$SRC/blocklists/ai-sites.txt}
ALLOWLIST=${ALLOWLIST:-$SRC/blocklists/allowlist.txt}
DNS_CONF=/etc/dnsmasq.d/10-school-filter-block.conf

[ -f "$BLOCKLIST" ] || { echo "blocklist not found: $BLOCKLIST" >&2; exit 1; }

# OpenWrt points dnsmasq's conf-dir at a generated path under /tmp, so files
# dropped in /etc/dnsmasq.d are silently ignored. Repoint it at a persistent
# directory. (Verified: without this, blocklist entries have no effect at all.)
mkdir -p /etc/dnsmasq.d
if [ "$(uci -q get dhcp.@dnsmasq[0].confdir || true)" != "/etc/dnsmasq.d" ]; then
  uci set dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
  uci commit dhcp
  DNS_DIRTY=1
else
  skip "dnsmasq confdir already /etc/dnsmasq.d"
fi

# Both address families are required. "address=/x/0.0.0.0" answers only A
# queries; AAAA still goes upstream and the site resolves over IPv6, so the
# block appears to work while doing nothing on a dual-stack client.
{
  printf '# Generated by scripts/setup-filter.sh -- do not edit.\n'
  printf '# Source: %s\n' "$BLOCKLIST"
  sed 's/#.*//' "$BLOCKLIST" | tr -d ' \t\r' | while read -r d; do
    [ -n "$d" ] || continue
    printf 'address=/%s/0.0.0.0\naddress=/%s/::\n' "$d" "$d"
  done
  if [ -f "$ALLOWLIST" ]; then
    printf '# Exceptions (most specific match wins).\n'
    sed 's/#.*//' "$ALLOWLIST" | tr -d ' \t\r' | while read -r d; do
      [ -n "$d" ] || continue
      printf 'server=/%s/#\n' "$d"
    done
  fi
} > "$DNS_CONF.new"

if [ -f "$DNS_CONF" ] && cmp -s "$DNS_CONF" "$DNS_CONF.new"; then
  rm -f "$DNS_CONF.new"
  skip "blocklist unchanged"
else
  mv "$DNS_CONF.new" "$DNS_CONF"
  DNS_DIRTY=1
fi

if [ "${DNS_DIRTY:-0}" = 1 ]; then
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || {
    echo "dnsmasq restart failed -- check $DNS_CONF" >&2; exit 1; }
  sleep 3
fi

# Prove a blocked domain is actually blocked, rather than trusting the restart.
PROBE=$(sed 's/#.*//' "$BLOCKLIST" | tr -d ' \t\r' | grep -v '^$' | head -1)
if [ -n "$PROBE" ]; then
  if nslookup "$PROBE" 127.0.0.1 2>/dev/null | grep -qE '(^|[^0-9])0\.0\.0\.0|Address: ::'; then
    printf '    blocking verified (%s)\n' "$PROBE"
  else
    echo "blocklist loaded but $PROBE still resolves -- not blocking" >&2
    exit 1
  fi
fi
printf '    %s domains blocked\n' "$(sed 's/#.*//' "$BLOCKLIST" | tr -d ' \t\r' | grep -vc '^$')"

###########################################################################
say "Installing certificate page on port $CERT_PORT"
###########################################################################
mkdir -p "$WWW/cgi-bin"

if [ -d "$SRC/certpage" ]; then
  cp "$SRC/certpage/index.html" "$WWW/index.html"
  cp "$SRC/certpage/cgi-bin/ca" "$SRC/certpage/cgi-bin/ios" "$WWW/cgi-bin/"
  # Screenshots are optional; the page drops any frame whose image is missing.
  if [ -d "$SRC/certpage/img" ]; then
    mkdir -p "$WWW/img"
    for f in "$SRC/certpage/img"/*.png "$SRC/certpage/img"/*.jpg; do
      [ -f "$f" ] && cp "$f" "$WWW/img/"
    done
    printf '    %s screenshot(s) installed\n' "$(ls -1 "$WWW/img" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  chmod 755 "$WWW/cgi-bin/ca" "$WWW/cgi-bin/ios"
  for f in "$WWW/cgi-bin/ca" "$WWW/cgi-bin/ios"; do
    [ -s "$f" ] || { echo "$f copied as an empty file" >&2; exit 1; }
  done
else
  echo "certpage/ not found next to this script" >&2; exit 1
fi

cp "$CA_DIR/ca.crt" "$WWW/school-ca.crt"
chmod 644 "$WWW/school-ca.crt"

# Show the fingerprint on the page so a student can check it against one posted
# in the classroom, rather than trusting whatever certificate a network offers.
FP=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')
sed "s|__FINGERPRINT__|$FP|" "$SRC/certpage/index.html" > "$WWW/index.html"

# iOS only opens a profile in Settings when it is a signed-or-plain
# .mobileconfig served as application/x-apple-aspen-config.
U1=$(cat /proc/sys/kernel/random/uuid)
U2=$(cat /proc/sys/kernel/random/uuid)
DER_B64=$(openssl x509 -in "$CA_DIR/ca.crt" -outform DER | openssl base64)
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0"><dict>'
  printf '%s\n' '<key>PayloadContent</key><array><dict>'
  printf '%s\n' '<key>PayloadCertificateFileName</key><string>school-ca.crt</string>'
  printf '%s\n' '<key>PayloadContent</key><data>'
  printf '%s\n' "$DER_B64"
  printf '%s\n' '</data>'
  printf '%s\n' '<key>PayloadDescription</key><string>Adds a certificate authority so school Wi-Fi can filter Google Search.</string>'
  printf '<key>PayloadDisplayName</key><string>%s</string>\n' "$CA_CN"
  printf '<key>PayloadIdentifier</key><string>school.filter.root.%s</string>\n' "$U1"
  printf '%s\n' '<key>PayloadType</key><string>com.apple.security.root</string>'
  printf '<key>PayloadUUID</key><string>%s</string>\n' "$U1"
  printf '%s\n' '<key>PayloadVersion</key><integer>1</integer>'
  printf '%s\n' '</dict></array>'
  printf '<key>PayloadDisplayName</key><string>%s</string>\n' "$CA_CN"
  printf '<key>PayloadIdentifier</key><string>school.filter.profile.%s</string>\n' "$U2"
  printf '%s\n' '<key>PayloadRemovalDisallowed</key><false/>'
  printf '%s\n' '<key>PayloadType</key><string>Configuration</string>'
  printf '<key>PayloadUUID</key><string>%s</string>\n' "$U2"
  printf '%s\n' '<key>PayloadVersion</key><integer>1</integer>'
  printf '%s\n' '</dict></plist>'
} > "$WWW/school-ca.mobileconfig"
chmod 644 "$WWW/school-ca.mobileconfig"

if apk info -e uhttpd >/dev/null 2>&1; then skip "uhttpd"; else apk add uhttpd; fi

uci -q delete uhttpd.certpage || true
uci set uhttpd.certpage=uhttpd
uci add_list uhttpd.certpage.listen_http="0.0.0.0:$CERT_PORT"
uci set uhttpd.certpage.home="$WWW"
uci set uhttpd.certpage.cgi_prefix='/cgi-bin'
uci add_list uhttpd.certpage.index_page='index.html'
uci commit uhttpd
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
sleep 2

if wget -q -O- "http://127.0.0.1:$CERT_PORT/" 2>/dev/null | grep -q 'School Wi-Fi Setup'; then
  printf '    cert page serving on port %s\n' "$CERT_PORT"
else
  echo "cert page is not responding on port $CERT_PORT" >&2; exit 1
fi

###########################################################################
say "Configuring explicit proxy port $EXPLICIT_PROXY_PORT"
###########################################################################
# The init script emits: http_port $http_port $http_port_options
uci set squid.squid.http_port="$EXPLICIT_PROXY_PORT"
uci set squid.squid.http_port_options="ssl-bump generate-host-certificates=on dynamic_cert_mem_cache_size=4MB tls-cert=$CA_DIR/ca.crt tls-key=$CA_DIR/ca.key"
uci commit squid

###########################################################################
say "Starting Squid"
###########################################################################
/etc/init.d/squid enable 2>/dev/null || true
rm -f /dev/shm/squid-*
/etc/init.d/squid restart >/dev/null 2>&1 || /etc/init.d/squid start >/dev/null 2>&1 || true
sleep 6
if pgrep squid >/dev/null 2>&1; then
  printf '    squid is running\n'
else
  echo "squid did not start. Recent log:" >&2
  logread | grep -i squid | tail -10 >&2
  exit 1
fi

# Flush everything to disk. An abrupt power loss -- or a VM killed rather than
# shut down -- can otherwise leave freshly written files at zero length, thanks
# to ext4 delayed allocation. A zero-byte url_rewrite_program makes Squid
# crash-loop with "redirector helpers are crashing too rapidly".
sync

say "Done."
echo
echo "CA for students to install:  $CA_DIR/ca.crt"
echo "Student LAN:                 $LAN_ADDR on $LAN_IF ($LAN_CIDR)"
echo "Access log:                  /var/log/squid/access.log"
