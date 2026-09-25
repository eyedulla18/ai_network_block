#!/bin/sh
#
# Squid external_acl_type helper: is this client approved?
#
# Reads one client address per line from the approvals file on every lookup, so
# a device approved by the portal takes effect without restarting or
# reconfiguring Squid. Squid caches results per-IP for the configured ttl.
#
# Protocol: one client address per line on stdin, "OK" or "ERR" per line out.
#
APPROVED=${APPROVED:-/etc/school-filter/approved.txt}

# Line buffering is mandatory. Without it the reply sits in the buffer and
# Squid waits forever for an answer that never arrives.
# Squid sends the format fields separated by spaces, and appends the ACL's
# own arguments as a final field -- "-" when there are none. So a request for
# 192.168.0.50 arrives as "192.168.0.50 -". Take the first field only;
# comparing the whole line never matches.
while IFS= read -r line; do
    ip=${line%% *}
    [ -n "$ip" ] || { echo "ERR"; continue; }
    if [ -f "$APPROVED" ] && grep -qxF "$ip" "$APPROVED" 2>/dev/null; then
        echo "OK"
    else
        echo "ERR"
    fi
done
