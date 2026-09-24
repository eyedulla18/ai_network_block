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

for _, f in ipairs(failures) do
  io.write("FAIL\n  ", f, "\n\n")
end

io.write(("%d cases, %d loop checks, %d failed\n"):format(total, checked_loops, failed))
os.exit(failed == 0 and 0 or 1)
