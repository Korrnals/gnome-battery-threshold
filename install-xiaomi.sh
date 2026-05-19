#!/bin/bash
# Quick install script for Xiaomi Redmi Book Pro 16 2025
set -e

echo "=== Battery Threshold Extension - Xiaomi Quick Install ==="
echo ""

# Check if running on Xiaomi Redmi Book Pro 16 2025
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")
if [[ ! "$PRODUCT_NAME" =~ [Rr]edmi.*[Bb]ook.*16.*2025 ]]; then
    echo "WARNING: This script is designed for Xiaomi Redmi Book Pro 16 2025"
    echo "Detected: $PRODUCT_NAME"
    echo "Continue anyway? (y/n)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for acpi_call
if [ ! -e "/proc/acpi/call" ]; then
    echo "ERROR: acpi_call not found!"
    echo "Please install acpi_call kernel module:"
    echo "  Fedora: rpm-ostree install acpi_call"
    echo "  Arch: pacman -S acpi_call"
    echo "  Ubuntu/Debian: apt install acpi-call-dkms"
    echo ""
    echo "Then reboot and run this script again."
    exit 1
fi

echo "✓ acpi_call detected"

# Build extension
echo "Building extension..."
./build.sh

# Install extension
EXTENSION_UUID="battery-threshold@Korrnals.dev"
VERSION=$(grep -oP '"version": \K[0-9]+' metadata.json)

echo "Installing extension..."
mkdir -p ~/.local/share/gnome-shell/extensions/
unzip -o "dist/${EXTENSION_UUID}-v${VERSION}.zip" -d ~/.local/share/gnome-shell/extensions/

# Install backend
echo "Installing backend..."
sudo cp battery-threshold-backend.py /usr/local/bin/
sudo chmod +x /usr/local/bin/battery-threshold-backend.py

# Install polkit policy
echo "Installing polkit policy..."
sudo cp com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/

# Install systemd service for auto-apply on boot
echo "Installing systemd service..."
sudo cp battery-thresholdd/battery-threshold-xiaomi.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable battery-threshold-xiaomi.service

# Enable extension
echo "Enabling extension..."
gnome-extensions enable "$EXTENSION_UUID" 2>/dev/null || true

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Log out and log back in (or restart GNOME Shell)"
echo "2. Open GNOME Extensions and enable 'Battery Threshold'"
echo "3. Click the battery icon in the system tray to configure"
echo ""
echo "The charge limit will be automatically applied on boot."
echo ""
echo "To test immediately:"
echo "  sudo systemctl start battery-threshold-xiaomi.service"
