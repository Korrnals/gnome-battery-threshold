# Installation Guide

This guide walks you through every step required to build and install
Battery Threshold from source — from dependency setup to the GNOME
extension appearing in your panel.

**Table of contents**

1. [Quick start](#1-quick-start)
2. [Build dependencies](#2-build-dependencies)
3. [Step 1 — Diagnose your system](#step-1--diagnose-your-system)
4. [Step 2 — Install kernel module (Xiaomi / ThinkPad)](#step-2--install-kernel-module-xiaomi--thinkpad)
5. [Step 3 — Build](#step-3--build)
6. [Step 4 — System install](#step-4--system-install)
7. [Step 5 — Enable the extension](#step-5--enable-the-extension)
8. [Step 6 — Verify](#step-6--verify)
9. [Immutable systems (Fedora Silverblue / Kinoite)](#immutable-systems-fedora-silverblue--kinoite)
10. [Uninstall](#uninstall)
11. [Troubleshooting](#troubleshooting)

---

## 1. Quick start

For the impatient — if Rust is installed and your hardware uses the
standard sysfs interface (most ASUS, Dell, Framework, MSI, Huawei):

```bash
git clone https://github.com/Korrnals/gnome-battery-threshold.git
cd gnome-battery-threshold
make build
sudo make install
# Log out and back in, then:
gnome-extensions enable battery-threshold@korrnals.github.io
```

For Xiaomi / Redmi or ThinkPad laptops, read Step 2 first.

---

## 2. Build dependencies

You need these tools installed **before** running `make build`:

| Tool | Purpose |
|---|---|
| `cargo` / `rust` ≥ 1.75 | Compile the daemon |
| `glib-compile-schemas` | Bundle GSettings schemas |
| `make` | Build orchestration |
| `zip` | Pack the extension (only for `make dist`) |

### Fedora / RHEL

```bash
sudo dnf install rust cargo glib2-devel make zip
```

### Fedora Silverblue / Kinoite (immutable)

Run inside a toolbox or via rpm-ostree overlay:

```bash
# Option A — toolbox (disposable container, no reboot)
toolbox create && toolbox enter
sudo dnf install rust cargo glib2-devel make zip

# Option B — rpm-ostree overlay (permanent, needs reboot)
sudo rpm-ostree install rust cargo glib2-devel make zip
sudo systemctl reboot
```

> **Note:** The Makefile auto-detects an immutable `/usr` and switches to
> `/usr/local` as the prefix.  Building can happen inside a toolbox; the
> actual `sudo make install` must run on the host.

### Ubuntu / Debian

```bash
sudo apt install cargo libglib2.0-dev-bin make zip
```

### Arch Linux / Manjaro

```bash
sudo pacman -S rust glib2 make zip
```

### openSUSE

```bash
sudo zypper install rust cargo glib2-devel make zip
```

---

## Step 1 — Diagnose your system

Before installing anything, run the built-in doctor:

```bash
make doctor
```

Example output on Fedora Silverblue with a Xiaomi laptop:

```
═══ Battery Threshold — System Doctor ═══

System:
  OS              : fedora (silverblue) 6.12.0-...
  /usr writable   : no (immutable)
  PREFIX picked   : /usr/local          ← auto-detected
  Target user     : abyss (/var/home/abyss)

Hardware:
  Chassis vendor  : XIAOMI
  Product name    : Xiaomi Redmi Book Pro 16 2025
  Xiaomi/Redmi    : yes
  ThinkPad        : no

Backend availability:
  sysfs charge_control_*   : no
  /proc/acpi/call          : no — acpi_call module not loaded  ← needs attention
  tpacpi-bat               : no

Installed components:
  daemon binary          ✗ /usr/local/libexec/battery-thresholdd
  systemd unit           ✗ /etc/systemd/system/battery-thresholdd.service
  ...

Recommendation:
  → Xiaomi laptop detected but acpi_call is missing.
    Run: make deps  for installation guide.
```

If `make doctor` shows `✓` for all components — you are already installed.
Run `make doctor` any time to check current state.

---

## Step 2 — Install kernel module (Xiaomi / ThinkPad)

> Skip this step if `doctor` shows `sysfs charge_control_*: yes`.

Xiaomi/Redmi and many ThinkPad models control the battery via ACPI calls
rather than standard sysfs.  This requires the `acpi_call` kernel module.

The Makefile knows your distro and prints exact commands:

```bash
make deps
```

### Fedora (standard, mutable `/usr`)

```bash
# 1. Enable COPR rhea/acpi_call:
sudo dnf install -y dnf-plugins-core
sudo dnf copr enable rhea/acpi_call

# 2. Install the DKMS module:
sudo dnf install acpi_call-dkms kernel-devel

# 3. Load now (without reboot):
sudo modprobe acpi_call

# 4. Verify:
test -e /proc/acpi/call && echo "OK — acpi_call is active"
```

### Fedora Silverblue / Kinoite (immutable)

Because the rootfs is read-only, kernel modules must be layered via
`rpm-ostree`, but DKMS `%post` cannot write to `/var/lib/dkms` during
compose on Atomic systems. Use the project out-of-tree flow instead:

```bash
# 1. Build out-of-tree and layer as local kmod RPM:
BATTERY_THRESHOLD_AUTO_DEPS=1 sudo make install-deps

# 2. Reboot into the staged deployment:
sudo systemctl reboot

# 3. After reboot, verify:
test -e /proc/acpi/call && echo "OK — acpi_call is active"
```

For technical rationale and alternatives, see ADR-0001 in
`docs/adr/ADR-0001-acpi-call-atomic-fedora.md`.

### Ubuntu / Debian

```bash
sudo apt install acpi-call-dkms
sudo modprobe acpi_call
test -e /proc/acpi/call && echo "OK"
```

### Arch Linux / Manjaro

```bash
sudo pacman -S acpi_call-dkms
sudo modprobe acpi_call
```

---

## Step 3 — Build

No root required.

```bash
make build
```

This runs:
1. `cargo build --release` — compiles the Rust daemon (~30 s on first run,
   seconds on subsequent runs thanks to incremental compilation)
2. Copies the GJS extension into `target/extension/` and compiles schemas
3. Generates `target/generated/` — systemd and D-Bus activation files with
   the correct `LIBEXECDIR` path substituted in (important on Silverblue
   where the path is `/usr/local/libexec/` instead of `/usr/libexec/`)

Expected output:
```
▸ Building daemon (battery-thresholdd)
   Compiling battery-thresholdd v0.1.0
    Finished release [optimized] target(s) in 28.43s
▸ Compiling GSettings schemas
▸ Preparing extension bundle
▸ Generating config files for PREFIX=/usr/local
```

---

## Step 4 — System install

Requires root.

```bash
sudo make install
```

What happens, in order:

| Sub-target | What it installs |
|---|---|
| `install-system` | Daemon binary → `LIBEXECDIR` (`/usr/local/libexec` or `/usr/libexec`) |
| | systemd unit → `/etc/systemd/system/` |
| | D-Bus policy + activation → `/etc/dbus-1/system.d/` and `/usr/[local/]share/dbus-1/system-services/` |
| | PolicyKit action → `/usr/[local/]share/polkit-1/actions/` |
| | GSettings schema → `/usr/[local/]share/glib-2.0/schemas/` |
| `install-extension` | Extension files → `~/.local/share/gnome-shell/extensions/battery-threshold@korrnals.github.io/` |
| `install-activate` | `systemctl daemon-reload && systemctl enable --now battery-thresholdd` |

To install **without** starting the daemon automatically:

```bash
sudo make install NO_ACTIVATE=1
```

---

## Step 5 — Enable the extension

GNOME Shell (especially on Wayland) does not discover new extensions until
you log out and back in.

1. **Log out** of your GNOME session and log back in.
2. Then enable the extension:

```bash
gnome-extensions enable battery-threshold@korrnals.github.io
```

Or use GNOME Extensions app / Extensions Manager GUI.

On X11 you can restart the shell in place without logging out:
`Alt+F2` → type `r` → `Enter`.  This does **not** work on Wayland.

---

## Step 6 — Verify

```bash
# Full health check (no root needed):
make doctor

# Extension visible:
gnome-extensions list --enabled | grep battery

# Daemon running:
systemctl status battery-thresholdd
```

Expected `doctor` output after successful installation:

```
Installed components:
  daemon binary          ✓ /usr/local/libexec/battery-thresholdd
  systemd unit           ✓ /etc/systemd/system/battery-thresholdd.service
  dbus policy            ✓ /etc/dbus-1/system.d/io.github.korrnals.BatteryThreshold.conf
  dbus activation        ✓ /usr/local/share/dbus-1/system-services/io.github.korrnals.BatteryThreshold.service
  polkit action          ✓ /usr/local/share/polkit-1/actions/io.github.korrnals.BatteryThreshold.policy
  gsettings schema       ✓ /usr/local/share/glib-2.0/schemas/io.github.korrnals.BatteryThreshold.gschema.xml
  extension              ✓ /var/home/abyss/.local/share/gnome-shell/extensions/battery-threshold@korrnals.github.io/metadata.json
  daemon (systemctl)     active
```

---

## Immutable systems (Fedora Silverblue / Kinoite)

Silverblue uses an ostree-managed, read-only `/usr`.  The Makefile handles
this transparently:

| Traditional Fedora | Silverblue |
|---|---|
| `/usr/libexec/battery-thresholdd` | `/usr/local/libexec/battery-thresholdd` |
| `/usr/share/…` | `/usr/local/share/…` |
| `dnf install` | `rpm-ostree install` (or toolbox for build tools) |

The `make generate` step rewrites the paths inside the generated systemd
unit and D-Bus activation file at build time — the source files under
`data/` are never modified.

**Typical Silverblue workflow:**

```bash
# Inside a toolbox (has cargo, glib2-devel):
toolbox enter
cd ~/LABs/Projects/BatteryThreshold
make build
exit   # leave toolbox

# On the host (sudo works on host for /etc and /usr/local):
sudo make install
make enable-extension   # after re-login
```

---

## Uninstall

```bash
sudo make uninstall
```

This:
- Stops and disables the systemd service
- Removes all installed files (binary, units, D-Bus, PolicyKit, schema)
- Removes the GNOME extension from `~/.local/share/gnome-shell/extensions/`
- Runs `daemon-reload`

> The state directory `/var/lib/battery-thresholdd` (saved thresholds) is
> intentionally left behind so reinstalling preserves your settings.
> Remove it manually if you want a clean slate:
> ```bash
> sudo rm -rf /var/lib/battery-thresholdd
> ```

---

## Troubleshooting

### `make build` fails — `glib-compile-schemas: command not found`

Install `glib2-devel` (Fedora) or `libglib2.0-dev-bin` (Ubuntu/Debian).

### Daemon installed but not starting

```bash
journalctl -u battery-thresholdd --no-pager -n 50
```

Common causes:
- `acpi_call` module missing (Xiaomi / ThinkPad) → run `make deps`
- D-Bus policy not reloaded → `sudo systemctl daemon-reload`

### Extension installed but not visible in panel

1. Make sure you **logged out and back in** (mandatory on Wayland).
2. Check extension is enabled: `gnome-extensions list --enabled`
3. Check for JS errors: `journalctl /usr/bin/gnome-shell -f`

### Extension visible but "Unsupported hardware"

The daemon is running but no backend could control the battery on this
hardware.  Run the hardware probe and open an issue:

```bash
bash scripts/probe.sh --json
```

Copy the JSON output into your bug report at
<https://github.com/Korrnals/gnome-battery-threshold/issues>.

### `sudo make install` fails on Silverblue — "Read-only file system"

Do **not** pass `PREFIX=/usr` on Silverblue.  Let the Makefile auto-detect
(it will pick `/usr/local`).  Or explicitly set `PREFIX=/usr/local`:

```bash
sudo make install PREFIX=/usr/local
```

### Schema compilation error after install on Silverblue

If `/usr/local/share/glib-2.0/schemas/` is not in GLib's default search
path, point GNOME at it:

```bash
export GSETTINGS_SCHEMA_DIR=/usr/local/share/glib-2.0/schemas
```

Alternatively, compile the schema into the extension directory (already
done automatically by `make install-extension`).
