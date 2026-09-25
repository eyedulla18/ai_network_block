#!/usr/bin/env lua5.4
--
-- Test runner for udm14.lua.
--
--     lua5.4 run-tests.lua
--
-- Reads cases.tsv and checks each case, then verifies the loop-safety
-- property: every URL the rewriter emits must itself pass unchanged.
--
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local udm14 = require("udm14")

local cases_path = here .. "/cases.tsv"
local fh = assert(io.open(cases_path, "r"), "cannot open " .. cases_path)

local total, failed, checked_loops = 0, 0, 0
local failures = {}

for line in fh:lines() do
  if line ~= "" and not line:match("^%s*#") then
    local input, want_action, want_url = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if not input then
      failed = failed + 1
      failures[#failures + 1] = ("malformed case line: %s"):format(line)
    else
      total = total + 1
      local got_action, got_url = udm14.decide(input)
      got_url = got_url or "-"

      if got_action ~= want_action or got_url ~= want_url then
        failed = failed + 1
        failures[#failures + 1] = table.concat({
          ("input:    %s"):format(input),
          ("expected: %s  %s"):format(want_action, want_url),
          ("actual:   %s  %s"):format(got_action, got_url),
        }, "\n  ")
      end

      -- Loop safety: whatever we emit must be a fixed point. If a redirect
      -- target were itself rewritten, the browser would bounce forever.
      if got_action == "REWRITE" then
        checked_loops = checked_loops + 1
        local again = udm14.decide(got_url)
        if again ~= "PASS" then
          failed = failed + 1
          failures[#failures + 1] = table.concat({
            ("LOOP: rewriting %s"):format(input),
            ("produced        %s"):format(got_url),
            ("which decides   %s (expected PASS)"):format(again),
          }, "\n  ")
        end
      end
    end
  end
end
fh:close()

-- Portal stamping. Kept out of cases.tsv because that table describes the URL
-- canonicalizer alone, which is the part worth porting to another language.
local portal_cases = {
  -- input url, client ip, expected action, expected url
  { "http://cert.school/cgi-bin/approve", "192.168.0.80", "REWRITE",
    "http://cert.school/cgi-bin/approve?ip=192.168.0.80" },
  { "http://cert.school:8080/cgi-bin/approve", "192.168.0.80", "REWRITE",
    "http://cert.school:8080/cgi-bin/approve?ip=192.168.0.80" },
  -- no client address supplied: leave it alone rather than stamping nothing
  { "http://cert.school/cgi-bin/approve", nil, "SKIP", "-" },
  { "http://cert.school/cgi-bin/approve", "-", "SKIP", "-" },
  -- only the approve endpoint, not the rest of the portal
  { "http://cert.school/", "192.168.0.80", "SKIP", "-" },
  { "http://cert.school/index.html", "192.168.0.80", "SKIP", "-" },
  -- a lookalike host must not be stamped
  { "http://cert.school.evil.example/cgi-bin/approve", "192.168.0.80", "SKIP", "-" },
  -- loop safety: the stamped URL must pass unchanged the second time
  { "http://cert.school/cgi-bin/approve?ip=192.168.0.80", "192.168.0.80", "SKIP", "-" },
  { "http://cert.school:8080/cgi-bin/approve?ip=192.168.0.80", "192.168.0.80", "SKIP", "-" },
  -- a stale or forged stamp from a different client is corrected, once
  { "http://cert.school/cgi-bin/approve?ip=10.0.0.9", "192.168.0.80", "REWRITE",
    "http://cert.school/cgi-bin/approve?ip=192.168.0.80" },
  -- google is unaffected by the client address being present
  { "https://www.google.com/search?q=x&udm=50", "192.168.0.80", "REWRITE",
    "https://www.google.com/search?q=x&udm=14" },
}

for _, c in ipairs(portal_cases) do
  total = total + 1
  local got_action, got_url = udm14.decide(c[1], c[2])
  got_url = got_url or "-"
  if got_action ~= c[3] or got_url ~= c[4] then
    failed = failed + 1
    failures[#failures + 1] = table.concat({
      ("portal: %s  (client %s)"):format(c[1], tostring(c[2])),
      ("expected: %s  %s"):format(c[3], c[4]),
      ("actual:   %s  %s"):format(got_action, got_url),
    }, "\n  ")
  end
end

for _, f in ipairs(failures) do
  io.write("FAIL\n  ", f, "\n\n")
end

io.write(("%d cases, %d loop checks, %d failed\n"):format(total, checked_loops, failed))
os.exit(failed == 0 and 0 or 1)
