#!/usr/bin/env bash
# probe.sh — print a hardware report useful for bug reports.
#
# Usage: bash scripts/probe.sh

set -u

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

say 'DMI'
for f in sys_vendor product_name product_version bios_version; do
    p="/sys/class/dmi/id/$f"
    printf '%-20s ' "$f:"
    [[ -r "$p" ]] && cat "$p" || echo '(unreadable)'
done

say 'Kernel'
uname -srm

say 'Power supplies'
ls /sys/class/power_supply/ 2>/dev/null || echo '(none)'

say 'Battery interfaces'
for bat in /sys/class/power_supply/BAT*; do
    [[ -e "$bat" ]] || continue
    echo "-- $bat"
    ls "$bat" | grep -E 'charge_control|capacity|status' || true
done

say 'acpi_call'
if [[ -e /proc/acpi/call ]]; then
    echo 'present'
else
    echo 'missing — install the acpi_call kernel module'
fi

say 'tpacpi-bat'
if command -v tpacpi-bat >/dev/null 2>&1; then
    tpacpi-bat -v
else
    echo 'not installed'
fi

say 'GNOME Shell'
gnome-shell --version 2>/dev/null || echo '(not detected)'

say 'Daemon'
if systemctl --quiet is-active battery-thresholdd.service 2>/dev/null; then
    echo 'running'
else
    echo 'not running (install with: sudo make install)'
fi
