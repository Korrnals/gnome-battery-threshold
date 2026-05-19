# Contributing to GNOME Battery Threshold

## Supported Devices

This extension aims to support as many laptop vendors as possible:

### Currently Supported
- **Xiaomi/Redmi** (via acpi_call) - Fixed thresholds: 40%, 50%, 60%, 70%, 80%
- **ASUS** (via sysfs) - Continuous range 0-100%
- **Dell** (via sysfs) - Continuous range 0-100%
- **ThinkPad/Lenovo** (via tpacpi-bat, acpi_call, or smapi)
- **Framework** (via sysfs) - Continuous range 0-100%
- **Huawei** (via sysfs)
- **Samsung** (via sysfs)
- **Sony** (via sysfs)

### Adding Support for New Devices

To add support for a new laptop vendor:

1. **Detect the vendor** in `battery-threshold-backend.py`:
   ```python
   # Add to VENDOR_PATHS or detect via DMI
   if 'your_vendor' in product_name.lower():
       vendors['your_vendor'] = 'method_name'
   ```

2. **Implement control functions**:
   ```python
   def set_your_vendor_threshold(start, end):
       # Implementation here
       pass
   ```

3. **Update UI** in `extension.js`:
   - Add to `VENDOR_CONFIGS` if using fixed thresholds
   - Or use continuous sliders for 0-100% range

4. **Add systemd service** if needed for auto-apply on boot

5. **Update documentation** in README.md and XIAOMI_SETUP.md

## Testing

### Manual Testing
```bash
# Check support
sudo python3 battery-threshold-backend.py check

# Get current thresholds
sudo python3 battery-threshold-backend.py get

# Set thresholds (example: 30-70%)
sudo python3 battery-threshold-backend.py set 30 70 1

# Disable
sudo python3 battery-threshold-backend.py set 0 100 0
```

### Extension Testing
```bash
# Build and install locally
./build.sh
mkdir -p ~/.local/share/gnome-shell/extensions/
unzip -o dist/battery-threshold@Korrnals.dev-v2.zip -d ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals.dev/
gnome-extensions enable battery-threshold@Korrnals.dev
```

## Code Style

- Python: PEP 8
- JavaScript (GJS): Follow GNOME Shell conventions
- Rust: `cargo fmt` and `cargo clippy`

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on actual hardware if possible
5. Update documentation
6. Submit PR with description of changes and tested devices

## Reporting Issues

When reporting issues, please include:
- Laptop model and vendor
- Output of `sudo python3 battery-threshold-backend.py check`
- GNOME Shell version
- Distribution and version
- Relevant logs from `journalctl -xe | grep battery-threshold`
