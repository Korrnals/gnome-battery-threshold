# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Rewritten Rust D-Bus daemon (`battery-thresholdd`) replacing the
  previous Python backend.
- Vendor abstraction with backends for standard sysfs, Xiaomi (via
  `acpi_call`), and ThinkPad.
- Unified slider-based UI in the GNOME Shell extension for all vendors;
  vendors with discrete steps are snapped transparently by the daemon.
- systemd unit, D-Bus system-service file, GSettings schema and
  PolicyKit action under `data/`.
- Makefile-driven build, install, lint and test workflow.
- Documentation: `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`,
  `docs/ADDING_VENDORS.md`, `docs/vendors/xiaomi.md`.

### Changed
- Extension UUID changed to `battery-threshold@korrnals.github.io` for
  the GNOME Extensions store namespace.
- D-Bus interface renamed to
  `io.github.korrnals.BatteryThreshold1` (system bus).

### Removed
- Python backend (`battery-threshold-backend.py`) — replaced by the Rust
  daemon.
- Vendor-specific systemd units; one unit now serves all vendors.
