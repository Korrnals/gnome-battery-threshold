# Development Guide

## Toolchain

| Tool       | Version | Why                              |
|------------|---------|----------------------------------|
| Rust       | 1.75+   | daemon                           |
| GNOME Shell| 45+     | extension target                 |
| GLib       | 2.76+   | gschema compilation              |
| make       | any     | build orchestration              |
| zip        | any     | extension packaging              |

Install on Fedora:

```bash
sudo dnf install rust cargo make glib2-devel zip gnome-shell
```

Install on Ubuntu/Debian:

```bash
sudo apt install cargo libglib2.0-dev-bin make zip gnome-shell
```

## Repository layout

```
.
├── data/                      System integration files
│   ├── dbus/                  D-Bus system service + policy XML
│   ├── policy/                PolicyKit action
│   ├── schemas/               GSettings schema
│   └── systemd/               systemd unit
├── docs/                      Project documentation
├── scripts/                   Helper scripts (probe, install-dev, …)
├── src/
│   ├── daemon/                Rust D-Bus daemon (battery-thresholdd)
│   └── extension/             GNOME Shell extension (GJS)
├── Makefile                   Top-level build/install
├── README.md
├── CONTRIBUTING.md
└── LICENSE
```

## Building

```bash
make build
```

This compiles the Rust daemon in release mode (`src/daemon/target/release/battery-thresholdd`)
and stages the GNOME Shell extension under `target/extension/` with
compiled gschemas.

## Running the daemon in development

```bash
# As root, with debug logging
sudo RUST_LOG=debug make daemon-dev
```

The daemon owns its system bus name. If `dbus-broker` complains that the
name is already taken, stop the installed service first:

```bash
sudo systemctl stop battery-thresholdd.service
```

You can introspect the running daemon with `busctl`:

```bash
busctl --system introspect io.github.korrnals.BatteryThreshold \
    /io/github/korrnals/BatteryThreshold
```

And exercise it manually:

```bash
busctl --system call io.github.korrnals.BatteryThreshold \
    /io/github/korrnals/BatteryThreshold \
    io.github.korrnals.BatteryThreshold1 \
    SetThresholds yyb 30 70 true
```

## Running the extension locally

```bash
# Stage build outputs to your user extension dir:
make build
mkdir -p ~/.local/share/gnome-shell/extensions/battery-threshold@korrnals.github.io
cp -r target/extension/* ~/.local/share/gnome-shell/extensions/battery-threshold@korrnals.github.io/

# Then on X11:  Alt+F2  →  r
# On Wayland:   log out and back in
gnome-extensions enable battery-threshold@korrnals.github.io
```

Logs:

```bash
journalctl -f -o cat /usr/bin/gnome-shell    # extension output
journalctl -f -u battery-thresholdd          # daemon output
```

## Tests

```bash
make test
make lint
```

Rust unit tests cover pure logic such as `xiaomi::snap` and the buffer
encoders. Integration tests against real hardware are out of scope for CI;
contributors are expected to test on the device they support before
opening a PR.

## Release process

1. Bump `version` in `src/daemon/Cargo.toml` and
   `src/extension/metadata.json`.
2. Update `CHANGELOG.md`.
3. Tag the commit: `git tag -s vX.Y.Z -m "Release vX.Y.Z"`.
4. `git push --tags` — CI will build and publish a release artifact.
