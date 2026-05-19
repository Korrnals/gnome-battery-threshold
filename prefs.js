import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class BatteryThresholdPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        
        const page = new Adw.PreferencesPage({
            title: _('General'),
            icon_name: 'dialog-information-symbolic',
        });
        window.add(page);
        
        const group = new Adw.PreferencesGroup({
            title: _('Battery Charge Thresholds'),
            description: _('Configure when to start and stop charging to prolong battery life. Recommended: 30-70%.'),
        });
        page.add(group);
        
        // Enable switch
        const enableRow = new Adw.SwitchRow({
            title: _('Enable Threshold Control'),
            subtitle: _('Turn on to limit battery charge levels'),
        });
        group.add(enableRow);
        settings.bind('enabled', enableRow, 'active', Gio.SettingsBindFlags.DEFAULT);
        
        // Start threshold
        const startRow = new Adw.SpinRow({
            title: _('Minimum Charge Level'),
            subtitle: _('Start charging when battery falls below this level'),
            adjustment: new Gtk.Adjustment({
                lower: 0,
                upper: 90,
                step_increment: 1,
                page_increment: 5,
                value: settings.get_int('threshold-start')
            }),
        });
        group.add(startRow);
        settings.bind('threshold-start', startRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        
        // End threshold
        const endRow = new Adw.SpinRow({
            title: _('Maximum Charge Level'),
            subtitle: _('Stop charging when battery reaches this level'),
            adjustment: new Gtk.Adjustment({
                lower: 10,
                upper: 100,
                step_increment: 1,
                page_increment: 5,
                value: settings.get_int('threshold-end')
            }),
        });
        group.add(endRow);
        settings.bind('threshold-end', endRow, 'value', Gio.SettingsBindFlags.DEFAULT);
        
        // Xiaomi info group
        const xiaomiGroup = new Adw.PreferencesGroup({
            title: _('Xiaomi Support'),
        });
        page.add(xiaomiGroup);
        
        const xiaomiRow = new Adw.ActionRow({
            title: _('Xiaomi RedmiBook Pro 16 2025'),
            subtitle: _('This device uses acpi_call for charge limiting. Supported limits: 40%, 50%, 60%, 70%, 80%. Requires acpi_call kernel module.'),
        });
        xiaomiGroup.add(xiaomiRow);
        
        // Info group
        const infoGroup = new Adw.PreferencesGroup({
            title: _('Information'),
        });
        page.add(infoGroup);
        
        const infoRow = new Adw.ActionRow({
            title: _('About'),
            subtitle: _('This extension uses pkexec to modify battery charge thresholds via sysfs or acpi_call. Not all laptops support this feature.'),
        });
        infoGroup.add(infoRow);
        
        // Validation
        settings.connect('changed::threshold-start', () => {
            let start = settings.get_int('threshold-start');
            let end = settings.get_int('threshold-end');
            if (start >= end - 10) {
                settings.set_int('threshold-end', Math.min(100, start + 10));
            }
        });
        
        settings.connect('changed::threshold-end', () => {
            let start = settings.get_int('threshold-start');
            let end = settings.get_int('threshold-end');
            if (end <= start + 10) {
                settings.set_int('threshold-start', Math.max(0, end - 10));
            }
        });
    }
}