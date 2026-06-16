# ADR-0001: acpi_call installation on Fedora Atomic

- Status: Accepted
- Date: 2026-06-16
- Decision Makers: BatteryThreshold maintainers

## Context

BatteryThreshold needs the Linux kernel module `acpi_call` on Xiaomi/Redmi and
some ThinkPad devices to access battery charge threshold controls via ACPI/WMI.

On Fedora Atomic variants (Silverblue/Kinoite/Sericea), attempts to install
`acpi_call-dkms` through `rpm-ostree` fail in `%post`:

- `Error! No write access to DKMS tree at /var/lib/dkms`
- `mkdir: cannot create directory '/var/lib/dkms': Read-only file system`

This happens during `rpm-ostree` compose sandbox execution where DKMS cannot
write required state under `/var/lib/dkms`.

## Decision

For Fedora Atomic, do not use DKMS as the primary installation path.

Use an out-of-tree build flow inside distrobox/toolbox:

1. Build `acpi_call.ko` against the running host kernel.
2. Package the module as a local kmod RPM (`acpi_call-kmod-<kver>.rpm`).
3. Layer the local kmod RPM with `rpm-ostree install`.
4. Persist module autoload with `/etc/modules-load.d/acpi_call.conf`.
5. For current boot, load with `insmod` if needed.

This flow is implemented by `make install-deps` on Atomic hosts.

## Consequences

### Positive

- Works reliably on Fedora Atomic where DKMS `%post` fails.
- Persists across reboots through layered local kmod RPM.
- Keeps user workflow unified via project Makefile.

### Trade-offs

- Requires container-side build toolchain (`kernel-devel`, `gcc`, `make`).
- For new kernels, module is updated by rerunning the build/layer workflow.
- Optional `acpi_call-rebuild.service` may still be useful for custom setups,
  but is not the default path.

## Verification

After applying the Atomic flow:

- `test -e /proc/acpi/call && echo OK`
- `lsmod | grep '^acpi_call'`
- `busctl --system get-property io.github.korrnals.BatteryThreshold /io/github/korrnals/BatteryThreshold io.github.korrnals.BatteryThreshold1 Supported Vendor`

Expected D-Bus values on supported Xiaomi hardware:

- `Supported = true`
- `Vendor = "xiaomi"`

## Notes

Related implementation references:

- `Makefile` targets: `deps`, `install-deps`, `install-acpi-rebuild`
- `data/rpm/acpi_call-kmod.spec`
- `data/systemd/acpi_call-rebuild.service.in`
