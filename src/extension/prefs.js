/* prefs.js
 *
 * Preferences window for the Battery Threshold extension.
 * Uses libadwaita widgets (GNOME 45+).
 */

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences, gettext as _} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

export default class BatteryThresholdPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        const page = new Adw.PreferencesPage({
            title: _('General'),
            icon_name: 'battery-good-symbolic',
        });
        window.add(page);

        // ─── Thresholds group ────────────────────────────────────────────
        const group = new Adw.PreferencesGroup({
            title: _('Charge Thresholds'),
            description: _('Limit battery charge to extend its lifespan. Recommended: 30–70%. Edit the values, then press Apply to push them to the daemon — nothing is sent until you do. On laptops whose firmware only supports a stop-charging threshold (e.g. Xiaomi), the daemon emulates the lower threshold in software: it engages the EC limit when the battery reaches End and releases it when the battery drops to Start, so the laptop charges back up.'),
        });
        page.add(group);

        const enableRow = new Adw.SwitchRow({
            title: _('Enable Thresholds'),
            subtitle: _('Apply the configured range below'),
        });
        group.add(enableRow);
        settings.bind('enabled', enableRow, 'active', Gio.SettingsBindFlags.DEFAULT);

        const startRow = new Adw.SpinRow({
            title: _('Start (%)'),
            subtitle: _('Begin charging when below this level'),
            adjustment: new Gtk.Adjustment({
                lower: 0, upper: 90, step_increment: 1, page_increment: 5,
            }),
        });
        group.add(startRow);
        settings.bind('threshold-start', startRow, 'value', Gio.SettingsBindFlags.DEFAULT);

        const endRow = new Adw.SpinRow({
            title: _('End (%)'),
            subtitle: _('Stop charging at this level'),
            adjustment: new Gtk.Adjustment({
                lower: 10, upper: 100, step_increment: 1, page_increment: 5,
            }),
        });
        group.add(endRow);
        settings.bind('threshold-end', endRow, 'value', Gio.SettingsBindFlags.DEFAULT);

        // Auto-correct invalid combinations
        settings.connect('changed::threshold-start', () => {
            const s = settings.get_int('threshold-start');
            const e = settings.get_int('threshold-end');
            if (s >= e - 10)
                settings.set_int('threshold-end', Math.min(100, s + 10));
        });
        settings.connect('changed::threshold-end', () => {
            const s = settings.get_int('threshold-start');
            const e = settings.get_int('threshold-end');
            if (e <= s + 10)
                settings.set_int('threshold-start', Math.max(0, e - 10));
        });

        // ─── Apply button ────────────────────────────────────────────────
        // Editing the rows above only writes to GSettings; the running
        // extension watches `apply-trigger` and only pushes to the daemon
        // when this counter changes. This keeps rapid spinner clicks and
        // slider drags from flooding D-Bus.
        const applyRow = new Adw.ActionRow({
            title: _('Apply now'),
            subtitle: _('Send the values above to the daemon'),
        });
        const applyButton = new Gtk.Button({
            label: _('Apply'),
            valign: Gtk.Align.CENTER,
            css_classes: ['suggested-action'],
        });
        applyButton.connect('clicked', () => {
            const cur = settings.get_uint('apply-trigger');
            settings.set_uint('apply-trigger', (cur + 1) >>> 0);
        });
        applyRow.add_suffix(applyButton);
        applyRow.set_activatable_widget(applyButton);
        group.add(applyRow);

        // ─── Appearance group ────────────────────────────────────────────
        const appearanceGroup = new Adw.PreferencesGroup({
            title: _('Appearance'),
        });
        page.add(appearanceGroup);

        const showIndicatorRow = new Adw.SwitchRow({
            title: _('Show indicator in top bar'),
            subtitle: _('When disabled, settings remain available from the Extensions app.'),
        });
        appearanceGroup.add(showIndicatorRow);
        settings.bind('show-indicator', showIndicatorRow, 'active', Gio.SettingsBindFlags.DEFAULT);

        // ─── About group ─────────────────────────────────────────────────
        const aboutGroup = new Adw.PreferencesGroup({title: _('About')});
        page.add(aboutGroup);

        const aboutRow = new Adw.ActionRow({
            title: _('Battery Threshold'),
            subtitle: _('A unified interface for controlling laptop charge thresholds across vendors. The hardware-specific logic lives in a Rust daemon.'),
        });
        aboutGroup.add(aboutRow);
    }
}
