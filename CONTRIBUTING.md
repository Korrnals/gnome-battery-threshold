# Contributing

Thank you for your interest in improving Battery Threshold! This document is the
short version — for a deeper dive into the codebase, see
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Quick start

```bash
git clone https://github.com/Korrnals/gnome-battery-threshold.git
cd gnome-battery-threshold
make build
make test
```

## How to contribute

1. **Open an issue first** for non-trivial changes so we can discuss design.
2. **Fork** the repo and create a topic branch from `main`.
3. **Run `make lint` and `make test`** before opening a PR.
4. **Sign off** your commits (`git commit -s`) to certify you wrote them.
5. **Open a pull request** describing the change and the hardware you tested on.

## Code style

- **Rust**: `cargo fmt` + `cargo clippy -- -D warnings`. Public items must
  have doc-comments.
- **JavaScript (GJS)**: 4-space indent, single quotes, semicolons. No
  bundlers — the extension must run as-is.
- **Commit messages**: imperative mood (`Add Xiaomi backend`, not
  `Added…`). Reference issues when applicable (`Fixes #42`).

## Adding support for a new vendor

See [docs/ADDING_VENDORS.md](docs/ADDING_VENDORS.md) for the step-by-step
guide. In short:

1. Implement `VendorBackend` for the vendor in `src/daemon/vendors/<name>.rs`.
2. Wire it into `vendors::detect_backend()`.
3. Add unit tests for value snapping and any pure-function logic.
4. Document the hardware specifics in `docs/vendors/<name>.md`.

The extension UI never needs changes: the `Step` D-Bus property tells the
client how to snap values, and the daemon enforces it anyway.

## Reporting hardware

If you have a laptop we don't support yet, please open an issue with:

- Brand, model, year
- Output of `sudo /usr/libexec/battery-thresholdd --probe` (once we ship a
  probe subcommand) or, until then:
  - `cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name`
  - `ls /sys/class/power_supply/BAT*/`
  - Whether `/proc/acpi/call` exists

## License

By contributing you agree that your contributions are licensed under
GPL-3.0-or-later.
