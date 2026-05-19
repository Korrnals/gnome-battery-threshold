# Architecture

This document describes how Battery Threshold is structured, the rationale
behind the major design decisions, and the contracts between components.

## Goals

1. **Hardware abstraction**: a single UI for every supported laptop family.
2. **Memory and type safety on the privileged side**: a long-running root
   process is a textbook case for Rust.
3. **Minimal extension footprint**: the GNOME Shell extension should be as
   thin as possible — every line that runs inside gnome-shell competes with
   the compositor for CPU.
4. **Persistence**: thresholds must survive reboots without user action.

## High-level diagram

```
   ┌─────────────────────────────────────────────────┐
   │  GNOME Shell process                            │
   │  ┌───────────────────────────────────────────┐  │
   │  │  Battery Threshold extension (GJS)        │  │
   │  │   · PanelMenu indicator                   │  │
   │  │   · Adw preferences                       │  │
   │  │   · D-Bus client (system bus)             │  │
   │  └─────────────────┬─────────────────────────┘  │
   └────────────────────┼────────────────────────────┘
                        │ system D-Bus
                        ▼
   ┌─────────────────────────────────────────────────┐
   │  battery-thresholdd (Rust, async tokio)         │
   │   · zbus interface impl                         │
   │   · vendor abstraction                          │
   │   · persistence to /var/lib                     │
   └─────────────┬───────────────┬───────────────────┘
                 │               │
        sysfs    │               │   /proc/acpi/call
                 ▼               ▼
   ┌──────────────────┐  ┌────────────────────┐
   │ /sys/class/...   │  │ acpi_call kernel   │
   │ charge_control_* │  │ module             │
   └──────────────────┘  └────────────────────┘
```

## Components

### GNOME Shell extension (`src/extension/`)

A thin GJS client that:
- Subscribes to the daemon's properties and `StateChanged` signal.
- Renders a slider-based panel menu and an Adw preferences window.
- Persists the user's preferred settings via GSettings.
- Calls `SetThresholds(start, end, enabled)` over D-Bus on apply.

The extension never touches hardware paths directly. It does not need
elevated privileges. If the daemon is not running, the extension shows
"Daemon unavailable" and disables its controls.

### Rust daemon (`src/daemon/`)

A `tokio`-based async service that owns the D-Bus name
`io.github.korrnals.BatteryThreshold` on the system bus. It is activated
on-demand by `dbus-daemon` via the service file in `data/dbus/`, and
managed by systemd via `data/systemd/battery-thresholdd.service`.

Internally the daemon is split into:

| Module          | Responsibility                                       |
|-----------------|------------------------------------------------------|
| `main.rs`       | tokio runtime, tracing setup, signal handling.       |
| `battery.rs`    | Battery discovery, DMI parsing.                      |
| `vendors/`      | Trait + per-vendor implementations.                  |
| `state.rs`      | Shared state, persistence to `/var/lib`.             |
| `dbus_service.rs` | The zbus `interface` impl.                          |
| `error.rs`      | Typed errors that map cleanly to `fdo::Error`.       |

### Vendor abstraction

```rust
#[async_trait]
trait VendorBackend {
    fn info(&self) -> &BackendInfo;          // static capabilities
    async fn get_thresholds(&self) -> ...;   // read current values
    async fn set_thresholds(&self, t) -> ...;// apply
    fn snap(&self, value: u8) -> u8;         // round to supported step
}
```

`BackendInfo` advertises the supported range and a `step` value. The
extension treats `step == 1` as a continuous slider and `step > 1` as a
discrete one. Either way the daemon always snaps values server-side, so
clients can request anything and get a guaranteed-valid result back.

This is the key trick that lets us hide hardware differences: Xiaomi only
supports {40, 50, 60, 70, 80}% but the extension still sees a slider; the
daemon picks the nearest legal value transparently.

### Hardware backends

#### `vendors::sysfs`

Reads/writes `charge_control_{start,end}_threshold` under
`/sys/class/power_supply/BATx/`. Works on ASUS, Dell, Framework, Huawei,
modern Lenovo and others — anything that has the upstream kernel
interface. Continuous 0–100% range.

#### `vendors::xiaomi`

Talks to the `WMID.WMAA` ACPI method through `/proc/acpi/call` (provided
by the [`acpi_call`] kernel module). The method accepts a 32-byte buffer
where byte 1 is the command (`0xfb` set / `0xfa` enable / `0xfb` + `0x00`
disable) and byte 6 is the limit code. Limit codes are derived from the
Arch Wiki research:

| End % | Byte |
|-------|------|
| 40    | 0x08 |
| 50    | 0x07 |
| 60    | 0x06 |
| 70    | 0x05 |
| 80    | 0x01 |

Since the ACPI method exposes no readback, we cache the last value we
wrote.

[`acpi_call`]: https://github.com/nix-community/acpi_call

#### `vendors::thinkpad`

Prefers the upstream sysfs interface on kernels ≥ 5.17, otherwise falls
back to invoking `tpacpi-bat` (perl helper).

## D-Bus contract

```xml
<interface name="io.github.korrnals.BatteryThreshold1">
  <property name="Supported"   type="b" access="read"/>
  <property name="Vendor"      type="s" access="read"/>
  <property name="BatteryPath" type="s" access="read"/>
  <property name="MinStart"    type="y" access="read"/>
  <property name="MaxEnd"      type="y" access="read"/>
  <property name="Step"        type="y" access="read"/>
  <property name="Start"       type="y" access="read"/>
  <property name="End"         type="y" access="read"/>
  <property name="Enabled"     type="b" access="read"/>
  <method  name="SetThresholds">
    <arg name="start" type="y" direction="in"/>
    <arg name="end"   type="y" direction="in"/>
    <arg name="enabled" type="b" direction="in"/>
  </method>
  <method  name="Refresh"/>
  <signal  name="StateChanged"/>
</interface>
```

- All percentage values are `y` (byte), 0–100.
- `Step` is `y` and is `>=1`.
- `SetThresholds` is the only mutating call. The daemon snaps the values.
- `StateChanged` fires after any successful `SetThresholds` and on a
  periodic 60-second background tick.

## Persistence

The daemon writes `/var/lib/battery-thresholdd/state.json` after each
successful `SetThresholds`. On startup it reads that file and, if
`enabled == true`, immediately re-applies the stored values. This is what
keeps thresholds across reboots on hardware that doesn't preserve them in
firmware (notably Xiaomi).

## Security

- The daemon runs as `root` (required to write to sysfs and `/proc/acpi`).
- The systemd unit applies aggressive hardening: `ProtectSystem=strict`,
  `MemoryDenyWriteExecute=yes`, `PrivateNetwork=yes`, etc.
- The D-Bus policy in `data/dbus/*.conf` allows any user to call methods;
  the daemon defers to PolicyKit for fine-grained authorization (planned
  for milestone 0.2 — currently every call is accepted from sessions on
  the system bus).
- The polkit action file in `data/policy/` is in place for the upcoming
  hook.

## What's intentionally not included

- **Power-profile integration** — out of scope for v0.1.
- **Calibration cycles** — out of scope.
- **Multi-battery laptops** — only the first battery is controlled in
  v0.1. The architecture is ready; see the TODO in `battery.rs`.
