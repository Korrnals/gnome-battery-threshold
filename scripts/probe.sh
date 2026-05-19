#!/usr/bin/env bash
# probe.sh — print a hardware report useful for bug reports.
#
# Usage:
#   bash scripts/probe.sh           # human-readable
#   bash scripts/probe.sh --json    # machine-readable JSON (paste into issues)

set -u

JSON=0
if [[ "${1:-}" == "--json" ]]; then
    JSON=1
fi

read_file() { [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo ""; }

# Collect data
DMI_VENDOR=$(read_file /sys/class/dmi/id/sys_vendor)
DMI_PRODUCT=$(read_file /sys/class/dmi/id/product_name)
DMI_VERSION=$(read_file /sys/class/dmi/id/product_version)
DMI_BIOS=$(read_file /sys/class/dmi/id/bios_version)
KERNEL=$(uname -srm)
OS_ID=$( (. /etc/os-release 2>/dev/null && echo "$ID") || echo unknown)
OS_VARIANT=$( (. /etc/os-release 2>/dev/null && echo "${VARIANT_ID:-}") || echo "")
OS_VERSION=$( (. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}") || echo "")

POWER_SUPPLIES=$(ls /sys/class/power_supply/ 2>/dev/null | tr '\n' ' ')

BAT_PATHS=()
for bat in /sys/class/power_supply/BAT*; do
    [[ -e "$bat" ]] && BAT_PATHS+=("$bat")
done

HAS_ACPI_CALL=$([[ -e /proc/acpi/call ]] && echo true || echo false)
HAS_TPACPI_BAT=$(command -v tpacpi-bat >/dev/null 2>&1 && echo true || echo false)
HAS_SYSFS_END=$(ls /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1)
[[ -n "$HAS_SYSFS_END" ]] && SYSFS_END_BOOL=true || SYSFS_END_BOOL=false

GNOME_VER=$(gnome-shell --version 2>/dev/null | awk '{print $NF}')
[[ -z "$GNOME_VER" ]] && GNOME_VER="unknown"

DAEMON_STATUS="not_installed"
if systemctl --quiet is-active battery-thresholdd.service 2>/dev/null; then
    DAEMON_STATUS="active"
elif systemctl --quiet is-enabled battery-thresholdd.service 2>/dev/null; then
    DAEMON_STATUS="installed_inactive"
fi

# Output
if [[ "$JSON" == "1" ]]; then
    # JSON output for bug reports
    json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    bats_json="["
    first=1
    for bat in "${BAT_PATHS[@]}"; do
        [[ "$first" == "1" ]] && first=0 || bats_json+=","
        manu=$(read_file "$bat/manufacturer")
        model=$(read_file "$bat/model_name")
        has_end=$([[ -e "$bat/charge_control_end_threshold" ]] && echo true || echo false)
        has_start=$([[ -e "$bat/charge_control_start_threshold" ]] && echo true || echo false)
        bats_json+=$(printf '{"path":"%s","manufacturer":"%s","model":"%s","has_charge_end":%s,"has_charge_start":%s}' \
            "$(json_str "$bat")" "$(json_str "$manu")" "$(json_str "$model")" "$has_end" "$has_start")
    done
    bats_json+="]"

    cat <<EOF
{
  "schema": "battery-threshold-probe/1",
  "system": {
    "os_id": "$(json_str "$OS_ID")",
    "os_variant": "$(json_str "$OS_VARIANT")",
    "os_version": "$(json_str "$OS_VERSION")",
    "kernel": "$(json_str "$KERNEL")"
  },
  "dmi": {
    "vendor": "$(json_str "$DMI_VENDOR")",
    "product": "$(json_str "$DMI_PRODUCT")",
    "version": "$(json_str "$DMI_VERSION")",
    "bios": "$(json_str "$DMI_BIOS")"
  },
  "backends": {
    "sysfs_charge_control_end": $SYSFS_END_BOOL,
    "acpi_call": $HAS_ACPI_CALL,
    "tpacpi_bat": $HAS_TPACPI_BAT
  },
  "batteries": $bats_json,
  "gnome_shell": "$(json_str "$GNOME_VER")",
  "daemon": "$DAEMON_STATUS"
}
EOF
    exit 0
fi

# Human-readable output
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

say 'System'
printf '%-20s %s\n' 'OS:'         "${OS_ID} ${OS_VARIANT:+($OS_VARIANT) }${OS_VERSION}"
printf '%-20s %s\n' 'Kernel:'     "$KERNEL"
printf '%-20s %s\n' 'GNOME Shell:' "$GNOME_VER"

say 'DMI'
printf '%-20s %s\n' 'Vendor:'     "$DMI_VENDOR"
printf '%-20s %s\n' 'Product:'    "$DMI_PRODUCT"
printf '%-20s %s\n' 'Version:'    "$DMI_VERSION"
printf '%-20s %s\n' 'BIOS:'       "$DMI_BIOS"

say 'Power supplies'
echo "${POWER_SUPPLIES:-(none)}"

say 'Battery interfaces'
for bat in "${BAT_PATHS[@]}"; do
    echo "-- $bat"
    manu=$(read_file "$bat/manufacturer")
    model=$(read_file "$bat/model_name")
    printf '   %-22s %s\n' 'manufacturer:' "$manu"
    printf '   %-22s %s\n' 'model:'        "$model"
    for f in charge_control_end_threshold charge_control_start_threshold \
             capacity status charge_behaviour; do
        if [[ -e "$bat/$f" ]]; then
            printf '   %-22s %s\n' "$f:" "$(cat "$bat/$f" 2>/dev/null || echo '?')"
        fi
    done
done

say 'Backend availability'
printf '%-22s %s\n' 'sysfs charge_control:' "$( [[ "$SYSFS_END_BOOL" == "true" ]] && echo "yes" || echo "no" )"
printf '%-22s %s\n' '/proc/acpi/call:'      "$( [[ "$HAS_ACPI_CALL" == "true" ]] && echo "present" || echo "MISSING — install acpi_call" )"
printf '%-22s %s\n' 'tpacpi-bat:'           "$( [[ "$HAS_TPACPI_BAT" == "true" ]] && echo "installed" || echo "not installed" )"

say 'Daemon'
case "$DAEMON_STATUS" in
    active)              echo 'running ✓' ;;
    installed_inactive)  echo 'installed but not running — try: sudo systemctl start battery-thresholdd' ;;
    not_installed)       echo 'not installed — run: sudo make install' ;;
esac

echo
echo 'For bug reports, run with --json and paste the output.'

