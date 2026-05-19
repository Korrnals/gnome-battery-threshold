<div align="center">

```
╔══════════════════════════════════════════════════════════════╗
║   🔋  Battery Threshold  ·  GNOME Shell Extension           ║
║   ──────────────────────────────────────────────────────    ║
║   Keep your battery healthy. Set it. Forget it.             ║
╚══════════════════════════════════════════════════════════════╝
```

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Rust](https://img.shields.io/badge/rust-1.75+-orange.svg)](https://www.rust-lang.org/)
[![GNOME Shell](https://img.shields.io/badge/GNOME-45--49-4A86CF.svg?logo=gnome&logoColor=white)](https://www.gnome.org/)
[![Build](https://img.shields.io/github/actions/workflow/status/Korrnals/gnome-battery-threshold/build.yml?branch=main&label=CI)](https://github.com/Korrnals/gnome-battery-threshold/actions)
[![Made with ❤️ by Korrnals](https://img.shields.io/badge/made%20by-Korrnals-blueviolet)](https://github.com/Korrnals)

</div>

# Battery Threshold

A GNOME Shell extension for managing laptop battery charge thresholds. Prolongs battery life by limiting maximum charge level.

## ✨ Features

- 🔋 **Universal interface** — Same UX for all supported devices
- 🦀 **Rust backend** — Memory-safe, type-safe, performant
- 🔌 **Vendor abstraction** — Hardware differences hidden behind a unified API
- 🔐 **PolicyKit integration** — Secure privilege escalation
- 🎛️ **Live control** — Adjust thresholds from the system tray
- 💾 **Persistent settings** — Auto-applied on boot via systemd
- 📊 **D-Bus API** — Programmable interface for scripts and other tools

## 🖥️ Supported Hardware

| Vendor | Control Method | Notes |
|--------|---------------|-------|
| ASUS, Dell, Framework, Huawei, MSI | Standard sysfs | Native kernel support |
| ThinkPad / Lenovo | `tpacpi-bat`, `acpi_call`, `tp_smapi` | Multiple fallbacks |
| Xiaomi / Redmi | `acpi_call` (WMI) | Snaps to 40/50/60/70/80% |
| Samsung | `samsung-laptop` driver | Vendor-specific |
| Sony VAIO | `sony-laptop` driver | Vendor-specific |

> **Note:** Devices with fixed threshold levels (e.g. Xiaomi) present the same slider UI; values are transparently rounded to the nearest supported step at the daemon layer.

## 📋 Requirements

- GNOME Shell 45 or newer
- systemd-based Linux distribution
- D-Bus
- PolicyKit
- For Xiaomi/Lenovo via ACPI: `acpi_call` kernel module
- For build: Rust 1.75+, `cargo`, `make`, `glib-compile-schemas`

## 📦 Installation

### From source

```bash
git clone https://github.com/Korrnals/gnome-battery-threshold.git
cd gnome-battery-threshold
make build
sudo make install
```

### Enable the extension

```bash
gnome-extensions enable battery-threshold@korrnals.github.io
```

Then log out and log back in (or restart the shell with `Alt+F2` → `r` on X11).

## 🚀 Usage

After enabling:

1. Click the battery icon in the top panel
2. Toggle **Enable Thresholds**
3. Adjust the **Start** and **End** sliders
4. Click **Apply**

The settings persist across reboots automatically.

## 🏗️ Architecture

```
┌────────────────────────────────────┐
│  GNOME Shell Extension (GJS)       │
│  · Panel indicator                 │
│  · Preferences (Adw)               │
│  · D-Bus client                    │
└────────────────┬───────────────────┘
                 │ system D-Bus
                 ▼
┌────────────────────────────────────┐
│  battery-thresholdd (Rust, async)  │
│  · zbus D-Bus service              │
│  · Vendor abstraction layer        │
│  · PolicyKit integration           │
└────────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────┐
│  Hardware backends                 │
│  · sysfs (charge_control_*)        │
│  · acpi_call (Xiaomi, Lenovo)      │
│  · tpacpi-bat (ThinkPad)           │
└────────────────────────────────────┘
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## 🛠️ Development

```bash
# Build everything
make build

# Run daemon in dev mode (no install needed)
make daemon-dev

# Run tests
make test

# Lint
make lint

# Create distribution archive
make dist
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the full development guide.

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

To add support for a new vendor, see [docs/ADDING_VENDORS.md](docs/ADDING_VENDORS.md).

## 📄 License

GPL-3.0-or-later. See [LICENSE](LICENSE) for details.

## � Author

**Korrnals**

- GitHub: [@Korrnals](https://github.com/Korrnals)
- Project: [gnome-battery-threshold](https://github.com/Korrnals/gnome-battery-threshold)

If this project helps you — a ⭐ on GitHub means a lot!

## �🙏 Credits

- ACPI research for Xiaomi: [ArchWiki — Xiaomi RedmiBook Pro 16 2025](https://wiki.archlinux.org/title/Xiaomi_RedmiBook_Pro_16_2025)
- GNOME Shell extension ecosystem
- The `zbus` and `tokio` Rust communities
