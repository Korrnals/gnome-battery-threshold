# Xiaomi / Redmi laptops

## Hardware tested

- Xiaomi RedmiBook Pro 16 2025 (kernel 6.11+)

Other Xiaomi / Redmi notebooks that ship with the same WMI ACPI method
(`\_SB.PC00.WMID.WMAA`) are expected to work but are not formally tested
yet. If you have one, please open an issue.

## Prerequisites

The kernel module `acpi_call` must be loaded. It exposes the
`/proc/acpi/call` file used to invoke arbitrary ACPI methods.

### Fedora / RHEL

```bash
sudo dnf install acpi_call
sudo modprobe acpi_call
echo acpi_call | sudo tee /etc/modules-load.d/acpi_call.conf
```

### Ubuntu / Debian

```bash
sudo apt install acpi-call-dkms
sudo modprobe acpi_call
echo acpi_call | sudo tee /etc/modules-load.d/acpi_call.conf
```

### Arch

```bash
sudo pacman -S acpi_call
sudo modprobe acpi_call
```

### Verification

```bash
ls -l /proc/acpi/call         # file must exist
lsmod | grep acpi_call        # module must be loaded
```

## Supported thresholds

The firmware only accepts a fixed set of end-thresholds. The daemon snaps
arbitrary requests to the nearest supported value, so the extension UI is
unchanged.

| Requested % | Applied % |
|-------------|-----------|
| 0–44        | 40        |
| 45–54       | 50        |
| 55–64       | 60        |
| 65–74       | 70        |
| 75–100      | 80        |

The start threshold has no effect on this hardware; the firmware always
resumes charging once below the configured ceiling minus its internal
hysteresis (~5%).

## ACPI method reference

```
\_SB.PC00.WMID.WMAA(0x0, 0x1, <buffer>)
```

`<buffer>` is 32 bytes. Only bytes 1 and 6 are meaningful:

| Byte | Meaning                                    |
|------|--------------------------------------------|
| 0    | Reserved (`0x00`)                          |
| 1    | Command: `0xfb` set limit / `0xfa` enable  |
| 2–5  | Reserved (`0x00 0x10 0x02 0x00`)           |
| 6    | Limit code (see table below)               |
| 7–31 | Reserved (`0x00`)                          |

### Limit codes (byte 6)

| End % | Code |
|-------|------|
| 40    | 0x08 |
| 50    | 0x07 |
| 60    | 0x06 |
| 70    | 0x05 |
| 80    | 0x01 |
| Off   | 0x00 (with command `0xfb`) |

The enable command (`0xfa`) must be sent **twice** in succession. We do
not know why; the Xiaomi PC Manager Windows tool does the same thing.

## Limitations

- **No readback.** The ACPI method returns nothing useful, so the daemon
  caches the last value it wrote. The cache is also persisted to
  `/var/lib/battery-thresholdd/state.json` so it survives daemon
  restarts.
- **Resets on reboot.** The firmware does not preserve the limit across
  power cycles. The systemd unit re-applies the cached value on boot
  before the user logs in.

## References

- [ArchWiki — Xiaomi RedmiBook Pro 16 2025](https://wiki.archlinux.org/title/Xiaomi_RedmiBook_Pro_16_2025)
- [`acpi_call`](https://github.com/nix-community/acpi_call)
