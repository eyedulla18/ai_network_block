#!/usr/bin/lua5.4
--
-- udm14.lua -- Squid url_rewrite_program for the School AI Filter.
--
-- Canonicalizes Google search URLs so they select the "Web" tab (udm=14),
-- which has no AI Overview, and can never select AI Mode (udm=50).
--
-- Squid spawns this as a pool of long-lived child processes and speaks a
-- line protocol over stdin/stdout:
--
--     in:   <url> [<url_rewrite_extras>...]
--     out:  OK status=302 url=<url>   (redirect)
--           ERR                       (leave unchanged)
--
-- Run directly to use as a filter for testing:
--     echo 'https://www.google.com/search?q=test' | lua5.4 udm14.lua
--
-- This file is both a module and a script. Requiring it exposes the logic
-- for tests; running it enters the Squid helper loop.
--
local modname = ...

local M = {}

-- udm values students are allowed to reach. 50 is AI Mode and must never
-- appear here. See PLAN.md for the observed behavior this is derived from.
M.ALLOW = {
  ["2"]  = true,  -- Images
  ["7"]  = true,  -- Videos
  ["12"] = true,  -- News
  ["14"] = true,  -- Web (no AI Overview)
  ["18"] = true,  -- Forums
  ["28"] = true,  -- Shopping
  ["36"] = true,  -- Books
}

M.DEFAULT_MODE = "14"

-- The captive portal's approve endpoint. When a device reaches the portal
-- through an explicit proxy, the web server sees the proxy's address rather
-- than the device's, and would approve the wrong host. Squid knows the real
-- client, so we stamp it onto the URL here; uhttpd always passes a query
-- string to CGI, unlike the headers it drops.
M.PORTAL_HOST = "cert.school"
M.APPROVE_PATH = "/cgi-bin/approve"

--------------------------------------------------------------------------
-- Encoding helpers
--------------------------------------------------------------------------

-- Google percent-decodes both parameter names and values, so we must too:
-- "%75dm=50" is a udm parameter as far as Google is concerned.
local function pct_decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- In values, "+" means space. Decode "+" first so that a literal plus
-- written as %2B survives as "+" rather than becoming a space.
local function decode_value(s)
  return pct_decode((s:gsub("%+", " ")))
end

-- RFC 3986 unreserved set; everything else is escaped. Space becomes %20.
local function pct_encode(s)
  return (s:gsub("[^A-Za-z0-9%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--------------------------------------------------------------------------
-- URL parsing
--------------------------------------------------------------------------

-- Returns scheme, host, path, query. Nil if this is not an http(s) URL.
local function split_url(url)
  local scheme, host, rest = url:match("^(https?)://([^/?#]+)(.*)$")
  if not scheme then return nil end
  local path  = rest:match("^([^?#]*)") or ""
  local query = rest:match("%?([^#]*)") or ""
  return scheme, host, path, query
end

-- Split on "&", then at the FIRST "=", then decode. Doing it in this order
-- means an encoded "%26" inside a value cannot split the pair.
local function parse_query(query)
  local params = {}
  if not query or query == "" then return params end
  for pair in query:gmatch("[^&]+") do
    local name, value = pair:match("^([^=]*)=(.*)$")
    if name then
      params[#params + 1] = { name = pct_decode(name), value = decode_value(value) }
    else
      -- A bare token with no "=" is still a parameter we do not recognize.
      params[#params + 1] = { name = pct_decode(pair), value = nil }
    end
  end
  return params
end

-- Second-level labels that appear in Google country domains such as
-- google.co.uk and google.com.au.
local SECOND_LEVEL = {
  co = true, com = true, net = true, org = true,
  edu = true, gov = true, ac = true,
}

-- Matches google.com, www.google.com, google.co.uk, www.google.vu.
--
-- Deliberately strict about the suffix. A pattern loose enough to allow
-- "co.uk" is also loose enough to allow "com.evil.example", which would let
-- any attacker register a host this code treats as Google. So the suffix is
-- either a single TLD label, or one known second-level label plus a TLD.
function M.is_google_host(host)
  host = host:gsub(":%d+$", ""):lower()

  local suffix = host:match("^www%.google%.(.+)$") or host:match("^google%.(.+)$")
  if not suffix then return false end

  -- google.com, google.vu
  if suffix:match("^%a%a+$") then return true end

  -- google.co.uk, google.com.au
  local second, tld = suffix:match("^(%a+)%.(%a%a+)$")
  if second and tld and SECOND_LEVEL[second] then return true end

  return false
end

--------------------------------------------------------------------------
-- Decision logic
--------------------------------------------------------------------------

-- Reduce the decoded parameters to the only three things we care about.
local function analyze(params)
  local a = { q = nil, q_count = 0, start = nil, start_count = 0,
              udms = {}, has_unknown = false }
  for _, p in ipairs(params) do
    if p.name == "q" then
      a.q = p.value
      a.q_count = a.q_count + 1
    elseif p.name == "start" then
      -- Per spec, a start value is collected only if it is all digits.
      -- As with udm, the last surviving value wins. The count tracks every
      -- parameter named start, including rejected ones, so that a URL
      -- carrying a junk start is never treated as canonical.
      a.start_count = a.start_count + 1
      if p.value ~= nil and p.value:match("^%d+$") then
        a.start = p.value
      end
    elseif p.name == "udm" then
      a.udms[#a.udms + 1] = p.value or ""
    else
      -- Anything else at all: tbm, uppercase UDM, sxsrf, tracking junk.
      a.has_unknown = true
    end
  end
  return a
end

-- A URL passes only if its decoded parameters are exactly q, optionally a
-- numeric start, and exactly one udm from the allow list. Nothing else.
local function passes(a)
  if a.has_unknown then return false end
  if a.q_count ~= 1 or a.q == nil then return false end
  if a.start_count > 1 then return false end
  -- A single start that failed the all-digits check leaves a.start nil.
  if a.start_count == 1 and a.start == nil then return false end
  if #a.udms ~= 1 then return false end
  return M.ALLOW[a.udms[1]] == true
end

-- The last udm wins, mirroring Google's own behavior, but only if it is
-- allowed. Anything else -- absent, empty, invalid, or AI Mode -- becomes 14.
local function choose_mode(a)
  local last = a.udms[#a.udms]
  if last and M.ALLOW[last] then return last end
  return M.DEFAULT_MODE
end

local function rebuild(host, a)
  local parts = {
    "https://", host, "/search?q=", pct_encode(a.q or ""),
    "&udm=", choose_mode(a),
  }
  if a.start ~= nil then
    parts[#parts + 1] = "&start=" .. a.start
  end
  return table.concat(parts)
end

-- Returns one of:
--   "SKIP"            not a Google search URL, do not touch it
--   "PASS"            already canonical, do not touch it
--   "REWRITE", url    redirect the client to url
-- client_ip is optional. When Squid supplies it (via url_rewrite_extras) and
-- the request is for the portal's approve endpoint, it is stamped onto the URL.
function M.decide(url, client_ip)
  local scheme, host, path, query = split_url(url)
  if not scheme then return "SKIP" end

  if client_ip and client_ip ~= "" and client_ip ~= "-"
     and host:gsub(":%d+$", ""):lower() == M.PORTAL_HOST
     and path == M.APPROVE_PATH then
    local want = "ip=" .. pct_encode(client_ip)
    -- Loop guard: once the address is stamped, leave the URL alone. Without
    -- this the redirect target matches again and the browser bounces forever.
    if query == want then return "SKIP" end
    return "REWRITE", scheme .. "://" .. host .. path .. "?" .. want
  end

  if not M.is_google_host(host) then return "SKIP" end
  if path ~= "/search" then return "SKIP" end

  local a = analyze(parse_query(query))
  if passes(a) then return "PASS" end

  local new_url = rebuild(host, a)

  -- Loop guard: a redirect target that would itself be rewritten would
  -- bounce the browser forever. Refuse to emit one. This should be
  -- unreachable; the test suite asserts it never fires.
  local _, nhost, npath, nquery = split_url(new_url)
  if not (nhost and npath == "/search" and passes(analyze(parse_query(nquery)))) then
    return "SKIP"
  end

  return "REWRITE", new_url
end

--------------------------------------------------------------------------
-- Squid helper loop
--------------------------------------------------------------------------

function M.main()
  -- Squid reads one line per request and waits. Without line buffering the
  -- reply sits in stdout's buffer and the proxy hangs. This is essential.
  io.stdout:setvbuf("line")

  for line in io.lines() do
    -- Squid sends: <url> [extras...]. We only need the first field.
    local url = line:match("^(%S+)")
    -- Squid appends url_rewrite_extras after the URL; ip= is the client.
    local client_ip = line:match("%sip=(%S+)")
    if url then
      local action, new_url = M.decide(url, client_ip)
      if action == "REWRITE" then
        io.write("OK status=302 url=", new_url, "\n")
      else
        io.write("ERR\n")
      end
    else
      io.write("ERR\n")
    end
  end
end

-- Running as a script (lua5.4 udm14.lua) gives modname == nil.
-- Being required by the test suite gives modname == "udm14".
if modname == nil then
  M.main()
end

return M
