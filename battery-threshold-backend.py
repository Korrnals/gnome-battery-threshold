#!/usr/bin/env python3
"""
Backend for GNOME Battery Threshold extension.
Detects and controls battery charge thresholds via sysfs.
Supports: standard sysfs charge_control_* interfaces, vendor-specific drivers.
"""

import os
import sys
import json
import subprocess
import logging

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

SYSFS_POWER = "/sys/class/power_supply"

# Vendor detection paths
VENDOR_PATHS = {
    'asus': "/sys/class/power_supply/BAT0/charge_control_end_threshold",
    'dell': "/sys/class/power_supply/BAT0/charge_control_end_threshold",
    'huawei': "/sys/class/power_supply/BAT0/charge_control_end_threshold",
    'framework': "/sys/class/power_supply/BAT0/charge_control_end_threshold",
    'samsung': "/sys/devices/platform/samsung/battery_life_extender",
    'sony': "/sys/devices/platform/sony-laptop/battery_care_limiter",
    'thinkpad_smapi': "/sys/devices/platform/smapi",
    'thinkpad_acpi': "/sys/class/power_supply/BAT0/charge_control_start_threshold",
}

# Xiaomi acpi_call mapping
XIAOMI_THRESHOLDS = {
    40: "0x08", 50: "0x07", 60: "0x06",
    70: "0x05", 80: "0x01"
}


def find_batteries():
    """Find all battery devices in sysfs."""
    batteries = []
    if not os.path.exists(SYSFS_POWER):
        return batteries
    for entry in os.listdir(SYSFS_POWER):
        path = os.path.join(SYSFS_POWER, entry)
        type_path = os.path.join(path, "type")
        if os.path.exists(type_path):
            with open(type_path, 'r') as f:
                if f.read().strip().lower() == "battery":
                    batteries.append(path)
    return batteries


def check_sysfs_support(battery_path):
    """Check if battery supports standard charge_control_* thresholds."""
    files = os.listdir(battery_path) if os.path.exists(battery_path) else []
    support = {
        'charge_control_start_threshold': 'charge_control_start_threshold' in files,
        'charge_control_end_threshold': 'charge_control_end_threshold' in files,
        'charge_control_limit': 'charge_control_limit' in files,
        'charge_control_limit_max': 'charge_control_limit_max' in files,
    }
    return support


def get_dmi_info():
    """Read DMI system information."""
    info = {}
    dmi_path = "/sys/class/dmi/id"
    if not os.path.exists(dmi_path):
        return info
    
    for key in ['sys_vendor', 'product_name', 'product_version', 'bios_version']:
        try:
            with open(os.path.join(dmi_path, key), 'r') as f:
                info[key] = f.read().strip()
        except:
            info[key] = 'unknown'
    return info


def detect_vendor():
    """Detect laptop vendor and supported control methods."""
    vendors = {}
    dmi = get_dmi_info()
    sys_vendor = dmi.get('sys_vendor', '').lower()
    product_name = dmi.get('product_name', '').lower()
    
    # Check standard sysfs first
    for vendor, path in VENDOR_PATHS.items():
        if os.path.exists(path):
            if vendor == 'thinkpad_smapi':
                vendors['thinkpad'] = 'smapi'
            elif vendor == 'thinkpad_acpi':
                if 'thinkpad' in product_name or 'lenovo' in sys_vendor:
                    vendors['thinkpad'] = 'acpi'
            elif vendor == 'samsung':
                vendors['samsung'] = True
            elif vendor == 'sony':
                vendors['sony'] = True
            else:
                vendors[vendor] = 'sysfs'
    
    # Check for Xiaomi with acpi_call
    if os.path.exists("/proc/acpi/call"):
        if 'redmi' in product_name or 'xiaomi' in sys_vendor:
            vendors['xiaomi'] = 'acpi_call'
        elif 'thinkpad' in product_name or 'lenovo' in sys_vendor:
            if 'thinkpad' not in vendors:
                vendors['thinkpad'] = 'acpi_call'
    
    # Check for tpacpi-bat (ThinkPad)
    if subprocess.run(['which', 'tpacpi-bat'], capture_output=True).returncode == 0:
        vendors['thinkpad_tpacpi'] = True
    
    return vendors, dmi


def get_sysfs_thresholds(battery_path):
    """Read thresholds from sysfs."""
    result = {'start': None, 'end': None}
    
    start_path = os.path.join(battery_path, "charge_control_start_threshold")
    end_path = os.path.join(battery_path, "charge_control_end_threshold")
    
    if os.path.exists(start_path):
        try:
            with open(start_path, 'r') as f:
                result['start'] = int(f.read().strip())
        except:
            pass
    
    if os.path.exists(end_path):
        try:
            with open(end_path, 'r') as f:
                result['end'] = int(f.read().strip())
        except:
            pass
    
    return result


def set_sysfs_thresholds(battery_path, start, end):
    """Set thresholds via sysfs."""
    errors = []
    
    if start >= end:
        errors.append(f"Invalid range: start ({start}) must be less than end ({end})")
        return errors
    
    start_path = os.path.join(battery_path, "charge_control_start_threshold")
    end_path = os.path.join(battery_path, "charge_control_end_threshold")
    
    # Write end first (some devices require this order)
    if os.path.exists(end_path):
        try:
            with open(end_path, 'w') as f:
                f.write(str(end))
        except PermissionError:
            errors.append(f"Permission denied: {end_path}")
        except Exception as e:
            errors.append(f"Error writing end threshold: {e}")
    
    if os.path.exists(start_path):
        try:
            with open(start_path, 'w') as f:
                f.write(str(start))
        except PermissionError:
            errors.append(f"Permission denied: {start_path}")
        except Exception as e:
            errors.append(f"Error writing start threshold: {e}")
    
    return errors


def reset_sysfs_thresholds(battery_path):
    """Reset thresholds to defaults (0-100)."""
    return set_sysfs_thresholds(battery_path, 0, 100)


def set_thinkpad_threshold(start, end, method='acpi'):
    """Set ThinkPad thresholds using various methods."""
    errors = []
    
    if method == 'tpacpi':
        try:
            subprocess.run(['tpacpi-bat', '-s', 'ST', '1', str(start)], check=True)
            subprocess.run(['tpacpi-bat', '-s', 'SP', '1', str(end)], check=True)
        except Exception as e:
            errors.append(f"tpacpi-bat error: {e}")
    
    elif method == 'acpi_call':
        try:
            with open("/proc/acpi/call", "w") as f:
                f.write(f"\\_SB.PCI0.LPC0.EC0.HKEY.BCSS {start}")
            with open("/proc/acpi/call", "w") as f:
                f.write(f"\\_SB.PCI0.LPC0.EC0.HKEY.BCSS {end}")
        except Exception as e:
            errors.append(f"acpi_call error: {e}")
    
    return errors


def get_thresholds(battery_path):
    """Read current thresholds from sysfs."""
    result = {'start': None, 'end': None}
    
    start_path = os.path.join(battery_path, 'charge_control_start_threshold')
    end_path = os.path.join(battery_path, 'charge_control_end_threshold')
    limit_path = os.path.join(battery_path, 'charge_control_limit')
    
    if os.path.exists(start_path):
        try:
            with open(start_path, 'r') as f:
                result['start'] = int(f.read().strip())
        except (ValueError, PermissionError):
            pass
    
    if os.path.exists(end_path):
        try:
            with open(end_path, 'r') as f:
                result['end'] = int(f.read().strip())
        except (ValueError, PermissionError):
            pass
    
    # Fallback to charge_control_limit
    if result['end'] is None and os.path.exists(limit_path):
        try:
            with open(limit_path, 'r') as f:
                result['end'] = int(f.read().strip())
        except (ValueError, PermissionError):
            pass
    
    return result


def set_thresholds(battery_path, start, end):
    """Set charge thresholds via sysfs."""
    errors = []
    
    # Try standard sysfs first
    start_path = os.path.join(battery_path, 'charge_control_start_threshold')
    end_path = os.path.join(battery_path, 'charge_control_end_threshold')
    
    if os.path.exists(start_path):
        try:
            with open(start_path, 'w') as f:
                f.write(str(start))
        except PermissionError:
            errors.append(f"Permission denied: {start_path}")
        except Exception as e:
            errors.append(f"Error writing {start_path}: {e}")
    
    if os.path.exists(end_path):
        try:
            with open(end_path, 'w') as f:
                f.write(str(end))
        except PermissionError:
            errors.append(f"Permission denied: {end_path}")
        except Exception as e:
            errors.append(f"Error writing {end_path}: {e}")
    
    # Try charge_control_limit for single-threshold systems
    if not os.path.exists(start_path) and not os.path.exists(end_path):
        limit_path = os.path.join(battery_path, 'charge_control_limit')
        if os.path.exists(limit_path):
            try:
                with open(limit_path, 'w') as f:
                    f.write(str(end))
            except PermissionError:
                errors.append(f"Permission denied: {limit_path}")
            except Exception as e:
                errors.append(f"Error writing {limit_path}: {e}")
    
    return errors


def reset_thresholds(battery_path):
    """Reset thresholds to defaults (0-100)."""
    return set_thresholds(battery_path, 0, 100)


def cmd_check():
    """Check if threshold control is supported."""
    batteries = find_batteries()
    if not batteries:
        print(json.dumps({
            'supported': False,
            'reason': 'No batteries found',
            'vendors': {}
        }))
        return
    
    vendors, dmi = detect_vendor()
    sysfs_support = check_sysfs_support(batteries[0])
    
    supported = bool(vendors) or any(sysfs_support.values())
    
    result = {
        'supported': supported,
        'vendors': vendors,
        'sysfs': sysfs_support,
        'dmi': dmi,
        'batteries': [os.path.basename(b) for b in batteries]
    }
    
    if not supported:
        result['reason'] = 'No supported battery control method found'
    
    print(json.dumps(result))


def cmd_get():
    """Get current thresholds."""
    batteries = find_batteries()
    if not batteries:
        print(json.dumps({'error': 'No batteries found'}))
        return
    
    vendors, _ = detect_vendor()
    
    # For Xiaomi, we can't read back the threshold easily
    if 'xiaomi' in vendors:
        print(json.dumps({
            'start': 0,
            'end': 70,
            'vendor': 'xiaomi',
            'note': 'Xiaomi thresholds cannot be read back via acpi_call'
        }))
        return
    
    thresholds = get_sysfs_thresholds(batteries[0])
    print(json.dumps(thresholds))


def cmd_set(start, end, enabled):
    """Set thresholds."""
    batteries = find_batteries()
    if not batteries:
        print(json.dumps({'error': 'No batteries found'}))
        sys.exit(1)
    
    vendors, _ = detect_vendor()
    errors = []
    
    if enabled == '0' or enabled == 'false':
        # Disable thresholds
        if 'xiaomi' in vendors:
            errors = disable_xiaomi_threshold()
        else:
            errors = reset_sysfs_thresholds(batteries[0])
    else:
        # Enable/set thresholds
        if 'xiaomi' in vendors:
            errors = set_xiaomi_threshold(int(end))
        elif 'thinkpad' in vendors:
            method = vendors.get('thinkpad', 'acpi')
            errors = set_thinkpad_threshold(int(start), int(end), method)
        else:
            errors = set_sysfs_thresholds(batteries[0], int(start), int(end))
    
    if errors:
        print(json.dumps({'success': False, 'errors': errors}))
        sys.exit(1)
    else:
        print(json.dumps({'success': True}))


def set_xiaomi_threshold(limit):
    """Set battery charge limit on Xiaomi laptops using acpi_call."""
    if not os.path.exists("/proc/acpi/call"):
        return ["acpi_call not available"]
    
    # Преобразуем процент в hex значение (как в ArchWiki)
    limit_hex = {
        40: "0x08",
        50: "0x07",
        60: "0x06",
        70: "0x05",
        80: "0x01"
    }.get(limit)
    
    if not limit_hex:
        return [f"Invalid limit {limit}%. Valid options: 40, 50, 60, 70, 80"]
    
    try:
        # Установка порога
        acpi_string = f"\\_SB.PC00.WMID.WMAA 0x0 0x1 {{ 0x00 0xfb 0x00 0x10 0x02 0x00 {limit_hex} 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }}"
        
        with open("/proc/acpi/call", "w") as f:
            f.write(acpi_string)
        
        # Включение ограничения (два вызова)
        for _ in range(2):
            with open("/proc/acpi/call", "w") as f:
                f.write("\\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00 0xfa 0x00 0x10 0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }")
        
        return []
    except Exception as e:
        return [f"Error setting Xiaomi threshold: {e}"]


def disable_xiaomi_threshold():
    """Disable battery charge limit on Xiaomi laptops."""
    if not os.path.exists("/proc/acpi/call"):
        return ["acpi_call not available"]
    
    try:
        # Отключение ограничения (два вызова)
        for _ in range(2):
            with open("/proc/acpi/call", "w") as f:
                f.write("\\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00 0xfb 0x00 0x10 0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }")
        
        return []
    except Exception as e:
        return [f"Error disabling Xiaomi threshold: {e}"]


def cmd_get():
    """Get current thresholds."""
    batteries = find_batteries()
    if not batteries:
        print(json.dumps({'error': 'No batteries found'}))
        return
    
    thresholds = get_thresholds(batteries[0])
    print(json.dumps(thresholds))


def cmd_set(start, end, enabled):
    """Set thresholds."""
    batteries = find_batteries()
    if not batteries:
        print(json.dumps({'error': 'No batteries found'}))
        sys.exit(1)
    
    # Проверяем, является ли устройство Xiaomi с acpi_call
    vendors = check_vendor_support()
    if 'xiaomi_acpi_call' in vendors:
        if enabled == '0' or enabled == 'false':
            errors = disable_xiaomi_threshold()
        else:
            # Для Xiaomi используем end как порог (40, 50, 60, 70, 80)
            errors = set_xiaomi_threshold(int(end))
        
        if errors:
            print(json.dumps({'success': False, 'errors': errors}))
            sys.exit(1)
        else:
            print(json.dumps({'success': True}))
        return
    
    # Стандартный путь через sysfs
    if enabled == '0' or enabled == 'false':
        errors = reset_thresholds(batteries[0])
    else:
        errors = set_thresholds(batteries[0], int(start), int(end))
    
    if errors:
        print(json.dumps({'success': False, 'errors': errors}))
        sys.exit(1)
    else:
        print(json.dumps({'success': True}))


def main():
    if len(sys.argv) < 2:
        print("Usage: battery-threshold-backend.py [check|get|set START END ENABLED]", file=sys.stderr)
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == 'check':
        cmd_check()
    elif cmd == 'get':
        cmd_get()
    elif cmd == 'set':
        if len(sys.argv) < 5:
            print("Usage: battery-threshold-backend.py set START END ENABLED", file=sys.stderr)
            sys.exit(1)
        cmd_set(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()