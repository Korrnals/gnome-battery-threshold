# Инструкция по настройке Battery Threshold на Xiaomi Redmi Book Pro 16 2025

## ⚠️ Важно: Ваш ноутбук НЕ поддерживает стандартный sysfs

Ваш Xiaomi Redmi Book Pro 16 2025 использует специфичный ACPI метод для управления порогом заряда. Это требует модуля ядра `acpi_call`.

## 📋 Пошаговая инструкция

### Шаг 1: Установка acpi_call

На Fedora Silverblue:

```bash
# Войти в toolbox (или использовать rpm-ostree)
rpm-ostree install acpi_call
# Перезагрузка ОБЯЗАТЕЛЬНА после установки модуля ядра
sudo systemctl reboot
```

После перезагрузки проверьте:
```bash
lsmod | grep acpi_call
# Должно показать: acpi_call

ls /proc/acpi/call
# Должно показать: /proc/acpi/call
```

### Шаг 2: Ручное тестирование (опционально)

```bash
# Загрузить модуль (если не загружен автоматически)
sudo modprobe acpi_call

# Установить порог 70%
echo '\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00 0xfb 0x00 0x10 0x02 0x00 0x05 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }' | sudo tee /proc/acpi/call

# Включить ограничение (выполнить 2 раза)
echo '\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00 0xfa 0x00 0x10 0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }' | sudo tee /proc/acpi/call
echo '\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00 0xfa 0x00 0x10 0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 }' | sudo tee /proc/acpi/call
```

### Шаг 3: Установка расширения GNOME

```bash
# Собрать расширение
cd /var/home/abyss/LABs/Projects/GnomeBatterySaver
chmod +x build.sh
./build.sh

# Установить (для Silverblue - в ~/.local)
mkdir -p ~/.local/share/gnome-shell/extensions/
unzip -o dist/battery-threshold@Korrnals.dev-v2.zip -d ~/.local/share/gnome-shell/extensions/battery-threshold@Korrnals.dev/

# Копировать backend
sudo cp battery-threshold-backend.py /usr/local/bin/
sudo chmod +x /usr/local/bin/battery-threshold-backend.py

# Установить systemd сервис для автозапуска
sudo cp battery-thresholdd/battery-threshold-xiaomi.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable battery-threshold-xiaomi.service
```

### Шаг 4: Настройка polkit (для D-Bus сервиса)

```bash
sudo cp com.Korrnals.battery-threshold.policy /usr/share/polkit-1/actions/
```

### Шаг 5: Перезагрузка и активация

```bash
# Перезагрузить GNOME (Alt+F2, ввести 'r' на X11, или перезайти в систему на Wayland)
# Включить расширение
gnome-extensions enable battery-threshold@Korrnals.dev
```

## 🔧 Таблица соответствия процентов и hex значений

| Процент | Hex значение |
|---------|-------------|
| 40%     | 0x08        |
| 50%     | 0x07        |
| 60%     | 0x06        |
| 70%     | 0x05        |
| 80%     | 0x01        |

## 🔄 Обновление прошивки (опционально)

Ваша текущая прошивка: **RMAAR6B0P0606**

Проверить обновления:
```bash
# Установить fwupd (если не установлен)
rpm-ostree install fwupd

# Перезагрузка
sudo systemctl reboot

# Проверить обновления
fwupdmgr refresh
fwupdmgr get-updates
```

Если доступны обновления:
```bash
fwupdmgr update
```

## 🐛 Отладка

Если что-то не работает:

1. Проверьте, загружен ли acpi_call:
   ```bash
   lsmod | grep acpi_call
   ```

2. Проверьте backend:
   ```bash
   sudo python3 /usr/local/bin/battery-threshold-backend.py check
   ```

3. Проверьте логи расширения:
   ```bash
   journalctl -xe | grep battery-threshold
   ```

4. Проверьте D-Bus сервис:
   ```bash
   systemctl status battery-threshold-xiaomi.service
   ```

## 📁 Файлы проекта

- `extension.js` - Основное расширение GNOME Shell
- `prefs.js` - Настройки расширения
- `battery-threshold-backend.py` - Python backend (с поддержкой acpi_call)
- `battery-thresholdd/` - Rust D-Bus сервис (опционально)
- `schemas/` - GSettings схемы
- `com.Korrnals.battery-threshold.policy` - Polkit политика

## 📝 Примечания

- Порог заряда сбрасывается при перезагрузке, поэтому используется systemd сервис для автоматического применения
- Для Xiaomi поддерживаются только пороги: 40%, 50%, 60%, 70%, 80%
- Рекомендуемый порог для сохранения здоровья батареи: **70%**
- Расширение автоматически определяет ваше устройство как Xiaomi и использует acpi_call
