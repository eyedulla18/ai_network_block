# URL rewriter

Squid `url_rewrite_program` that canonicalizes Google search URLs so they
select the "Web" tab (`udm=14`), which carries no AI Overview, and can never
select AI Mode (`udm=50`).

| File | Purpose |
|---|---|
| `udm14.lua` | The helper. Also loadable as a module, which is how the tests reach it. |
| `cases.tsv` | Test cases, tab-separated and language-agnostic. |
| `run-tests.lua` | Runner. Exits non-zero on failure. |

## Running the tests

```sh
lua5.4 run-tests.lua
```

No Squid, no VM and no OpenWrt required. On macOS: `brew install lua@5.4`,
then `/opt/homebrew/opt/lua@5.4/bin/lua5.4 run-tests.lua`.

## Trying it by hand

The helper is a line filter, so it can be driven straight from a shell:

```sh
echo 'https://www.google.com/search?q=photosynthesis' | lua5.4 udm14.lua
# OK status=302 url=https://www.google.com/search?q=photosynthesis&udm=14
```

## Squid configuration

```
url_rewrite_program  /usr/bin/udm14.lua
url_rewrite_children 20 startup=5 idle=2 concurrency=0
url_rewrite_access   allow gsearch
```

`concurrency` must stay `0`. Any other value makes Squid prefix each line
with a channel ID, which this helper does not parse.

The interpreter is installed by the `lua5.4` package at **`/usr/bin/lua5.4`**.
There is no `/usr/bin/lua` symlink, so the shebang has to name it exactly.

## Behavior

Three outcomes:

- **SKIP** — not a Google search URL. Squid is told `ERR`, nothing changes.
- **PASS** — already canonical. Also `ERR`.
- **REWRITE** — a 302 to the canonical form.

A URL passes only if its decoded parameters are exactly `q`, optionally a
numeric `start`, and exactly one `udm` from the allow list. Anything else is
rewritten.

Decisions are made on **decoded** parameter names and values, because Google
decodes them too: `%75dm=50` is a `udm` parameter, and `udm=%35%30` is AI
Mode. Parameter names are case-sensitive, so `UDM=50` is an unrecognized
parameter rather than a mode selector.

Where several `udm` values appear, the last one wins, mirroring Google. If
that value is not in the allow list — absent, empty, invalid, or `50` — the
mode becomes `14`.

## Two properties worth keeping

**Loop safety.** Every URL the rewriter emits must itself pass unchanged. If
a redirect target were rewritten again the browser would bounce forever. The
runner asserts this on every rewrite case, and `decide()` refuses to emit a
target that would not pass.

**Output buffering.** `io.stdout:setvbuf("line")` in the helper loop is
essential, not stylistic. Lua buffers stdout when it is not a terminal;
without that line the reply sits in the buffer, Squid waits for a response
that never arrives, and the proxy hangs with nothing useful in the log.

## Host matching

Deliberately strict. A pattern loose enough to allow `google.co.uk` is also
loose enough to allow `google.com.evil.example`, so the suffix must be either
a single TLD label or one known second-level label plus a TLD. See the test
cases at the end of `cases.tsv`.

## Not yet handled

Google's page issues background requests to `/search` with many parameters;
canonicalizing those breaks the page. The plan is to apply full
canonicalization only when `Sec-Fetch-Mode: navigate`, and to block decoded
`udm=50` on every request. Squid can pass that header through
`url_rewrite_extras`, which arrives as the trailing fields the helper
currently ignores. Open question 2 in `../PLAN.md`.
