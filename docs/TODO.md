# Documentation & benchmark TODO

Checklist for the docs/bench pass (updated as items land).

## Tables
- [x] `docs/config.md` — escape unescaped `|` inside cells (`precompressed gz\|br\|zstd`, `sub_filter_once on\|off`, `accel on\|off`)
- [x] `bench/BENCH.md` — unified table separator has 5 columns for a 4-column header
- [x] `docs/milestones.md` — row with an unescaped pipe (4 cells for a 3-column table)
- [x] Re-scan every tracked markdown file with the table checker after edits (0 broken rows)

## `docs/config.md`
- [x] Explain `accel` properly: what `X-Accel-Redirect` is, the internal-redirect loop, GET/HEAD rule, worked example
- [x] Fresh-feature coverage: named locations, `internal`, `return 444`, `proxy_hide_header`, `proxy_pass` URI tail, upstream TLS keepalive, chunked/large upstream bodies, `Expect: 100-continue`, per-vhost TLS + SNI, ACME renewal
- [x] One runnable example snippet per new feature (pointing at `examples/`)

## README
- [ ] Feature bullets for everything shipped lately (named/internal locations, 444, proxy_hide_header, 100-continue, chunked upstream, sub_filter/accel/precompressed twins, SNI certs, ACME)
- [ ] Correct the stale test count
- [ ] Link the `examples/` directory

## Example configs (`examples/`)
- [x] `12-locations.conf` — named locations, `internal`, `return 444`, `try_files @app` (compiles)
- [x] Proxy extras shipped as `11-full.conf` + the config.md "Proxy extras" example (`13-filters.conf` is the filters example)
- [x] `14-acme.conf` — ACME auto-HTTPS + renewal (compiles)
- [x] `15-sni-vhosts.conf` — per-vhost certificates with SNI selection (compiles)
- [x] Extend `11-full.conf` with the new directives (compiles)

## Benchmarks
- [ ] Extend `bench/modules-bench.sh` with cells: `return` template, named-location fallback, `accel` (X-Accel-Redirect), `sub_filter`, `gzip`, `proxy_hide_header`, `precompressed br` (note: nginx OSS serves gz)
- [ ] Extend the nginx module template + the shared origin with equivalent routes
- [ ] Run the extended suite (interleaved reps) and collect medians
- [ ] `bench/BENCH.md`: replace the module table with the big all-feature table vs nginx + methodology note
- [ ] Re-run `unified.sh`/matrix if the harness changed materially

## Process
- [ ] Commit + push after each bullet group; keep this file's checkboxes current
