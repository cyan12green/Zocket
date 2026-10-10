# Contributing

Contributions are welcome: bug reports, fixes, documentation, tests and
features. This page covers the basics; the detailed development conventions
live in [`AGENTS.md`](AGENTS.md) and the source layout in
[`docs/LAYOUT.md`](docs/LAYOUT.md).

## Getting started

Zocket builds with the Zig snapshot pinned in `build.zig.zon` (0.18.0-dev).
There are no runtime dependencies.

```sh
git clone --recurse-submodules <repository>
cd zocket
zig build test          # all tests (library + exe)
zig build run           # HTTP server on :8080
```

Submodules are only needed for benchmarks and cross-server comparisons; a
plain `git clone` is enough to build and test the server.

## Making changes

- **Add tests.** New functionality needs inline `test` blocks in the
  affected source file, and fixes should come with a regression test where
  practical. `zig build test` must stay green.
- **Keep commits focused.** One logical change per commit, with a message
  that explains the reason for the change.
- **Update documentation.** Configuration changes belong in
  [`docs/config.md`](docs/config.md) (and usually an example under
  `examples/`); user-visible behaviour changes belong in the
  [README](README.md) and [`docs/milestones.md`](docs/milestones.md).
- **Prefer compile-time work.** The codebase pushes parsing, validation and
  dispatch into comptime wherever the compiler allows; see the conventions
  in [`AGENTS.md`](AGENTS.md) before adding runtime tables or loops over
  data that is known at build time.
- **Measure performance changes.** Hot-path changes should come with a
  same-day A/B measurement (the benchmark harnesses interleave and pin
  CPUs; see [`bench/BENCH.md`](bench/BENCH.md) for methodology).

## Reporting issues

Include the Zig version, the configuration (or a minimal reproduction), the
command that triggers the problem, and any relevant server output
(`--logfile` or stderr). Crashes are best reported with a stack trace.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE.md).
