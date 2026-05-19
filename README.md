# Battery Charge Threshold — Universal GNOME Shell Extension

[![GNOME Extensions](https://img.shields.io/badge/GNOME%20Extensions-v2.0-blue?logo=gnome)](https://extensions.gnome.org/extension/XXXX/battery-charge-threshold/)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Build Status](https://github.com/Korrnals/gnome-battery-threshold/actions/workflows/build.yml/badge.svg)](https://github.com/Korrnals/gnome-battery-threshold/actions)

Universal GNOME Shell extension for managing laptop battery charge thresholds. Supports Xiaomi, ASUS, ThinkPad, Framework, Dell, Huawei, Samsung, Sony and more.

## 📦 Installation

### Method 1: From GNOME Extensions (recommended)
1. Visit [extensions.gnome.org](https://extensions.gnome.org/extension/XXXX/battery-charge-threshold/)
2. Toggle the switch
3. Install polkit policy (see below)

### Method 2: Manual Installation

```bash
git clone https://github.com/Korrnals/gnome-battery-threshold.git
cd gnome-battery-threshold
./build.sh
```

Then install the extension:
```bash
# For current user
mkdir -p ~/.local/share/gnome-shell/extensions/
unzip -o dist/battery-threshold@Korrnals.dev-v2.zip -d ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals.dev/

# Install backend
sudo cp battery-threshold-backend.py /usr/local/bin/
sudo chmod +x /usr/local/bin/battery-threshold-backend.py

# Install polkit policy
sudo cp com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/

# Enable extension
gnome-extensions enable battery-threshold@Korrnals.dev
```

## 🖥️ Supported Devices

| Vendor | Method | Threshold Type |
|--------|--------|---------------|
| **Xiaomi/Redmi** | acpi_call | Fixed: 40%, 50%, 60%, 70%, 80% |
| **ASUS** | sysfs | Continuous: 0-100% |
| **Dell** | sysfs | Continuous: 0-100% |
| **ThinkPad/Lenovo** | tpacpi-bat/acpi_call/smapi | Continuous: 0-100% |
| **Framework** | sysfs | Continuous: 0-100% |
| **Huawei** | sysfs | Continuous: 0-100% |
| **Samsung** | sysfs | Fixed levels |
| **Sony** | sysfs | Fixed levels |

### Xiaomi/Redmi Specific Setup

For Xiaomi Redmi Book Pro 16 2025 and similar models, see [XIAOMI_SETUP.md](XIAOMI_SETUP.md) for detailed instructions.

Quick setup:
```bash
# Install acpi_call (Fedora Silverblue example)
rpm-ostree install acpi_call
# REBOOT!

# Run quick install script
chmod +x install-xiaomi.sh
./install-xiaomi.sh
```

## ✨ Features

- 🎚️ Configure min/max charge levels
- 🔋 System tray indicator
- 🔔 Notifications on apply
- ⚡ Standard sysfs `charge_control_*` support
- 🔒 Safe application via `pkexec`
- 🖥️ Vendor-specific support (Xiaomi, ASUS, ThinkPad, etc.)
- 🔄 Auto-apply on boot via systemd

## 🏗️ Building from Source

### Requirements
- `gnome-shell` (for schema compilation)
- `cargo` (for Rust backend, optional)
- `python3` (for Python backend)
- `zip` (for packaging)

### Build
```bash
./build.sh
```

This creates `dist/battery-threshold@Korrnals.dev-v2.zip` ready for installation.

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on adding support for new devices.

## 📝 License

GPL-3.0 - see [LICENSE](LICENSE) file.

## 🙏 Acknowledgments

- [ArchWiki - Xiaomi RedmiBook Pro 16 2025](https://wiki.archlinux.org/title/Xiaomi_RedmiBook_Pro_16_2025) for acpi_call research
- GNOME Shell team for the extension API
- All contributors who test on their hardware

### 2. Компиляция схемы

```bash
glib-compile-schemas schemas/
```

### 3. Установка расширения

```bash
mkdir -p ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals
cp -r * ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/
```

### 4. Установка polkit policy (для pkexec)

**Fedora Silverblue / Atomic Desktop:**
```bash
# Скопируйте policy файл в overlay
sudo cp ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/
# Или используйте rpm-ostree для постоянной установки
sudo install -Dm644 ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/com.Korrnals.battery-threshold.policy
```

**Обычный Fedora / Другие дистрибутивы:**
```bash
sudo cp ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/
```

### 5. Перезагрузка GNOME Shell

Нажмите `Alt+F2`, введите `r` (на X11) или перезайдите в систему (на Wayland).

### 6. Включение расширения

Откройте **Extensions** или **GNOME Tweaks** и включите **Battery Charge Threshold**.

## Требования

- GNOME Shell 45+
- Python 3
- `pkexec` (обычно входит в `polkit`)
- Поддержка порогов зарядки на уровне ядра/драйверов

## Проверка поддержки

Выполните в терминале:

```bash
python3 ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/battery-threshold-backend.py check
```

Если ваш ноутбук поддерживает управление порогами, вы увидите `supported: true`.

### Проверка доступных интерфейсов

```bash
ls /sys/class/power_supply/BAT*/charge_control_*
```

Если файлы существуют — ваш ноутбук поддерживает функцию.

### Проверка для Xiaomi

На Xiaomi Redmi Book Pro и подобных:

```bash
# Проверьте наличие интерфейса
ls /sys/class/power_supply/BAT0/charge_control_end_threshold

# Попробуйте установить порог вручную (требует root)
echo 70 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

## Fedora Silverblue

На Silverblue расширение работает в user-space, но для изменения порогов требуется `pkexec`.

```bash
# Установка расширения
mkdir -p ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals
cp -r * ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/
glib-compile-schemas ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/schemas/

# Установка polkit policy (в overlay)
sudo cp ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/

# Перезагрузите сессию GNOME
```

## Использование

1. Нажмите на иконку батареи в панели
2. Включите **Enable Thresholds**
3. Настройте **Min** и **Max** ползунками
4. Нажмите **Apply Now**

Или откройте настройки расширения через **Settings** → **Extensions**.

## Устранение неполадок

### "Threshold control not available"

Ваш ноутбук/ядро не поддерживает управление порогами зарядки. Проверьте:

```bash
sudo dmesg | grep -i battery
lsmod | grep -i acpi
```

### "Permission denied"

Убедитесь, что polkit policy установлен:

```bash
ls /usr/share/polkit-1/actions/com.Korrnals.battery-threshold.policy
```

Проверьте что `pkexec` работает:

```bash
pkexec echo test
```

### Не применяются настройки

Проверьте backend вручную:

```bash
pkexec python3 ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/battery-threshold-backend.py set 30 70 1
```

### Проверка текущих порогов

```bash
python3 ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals/battery-threshold-backend.py get
```

## Поддерживаемые устройства

- **Xiaomi** Redmi Book Pro, Mi Notebook Pro (через sysfs)
- **ASUS** (через sysfs)
- **Dell** (через sysfs)
- **Lenovo/ThinkPad** (через tp_smapi или acpi_call)
- **Framework Laptop** (через sysfs)
- **Huawei** (через sysfs)
- **Samsung** (через platform driver)
- **Sony** (через sony-laptop driver)

## Автор

© 2026 Korrnals <korrnals@gmail.com>

## Лицензия

GPL-3.0