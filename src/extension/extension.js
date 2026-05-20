/* extension.js
 *
 * Battery Threshold — GNOME Shell extension
 * Copyright (C) 2026 Korrnals
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';

import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Slider} from 'resource:///org/gnome/shell/ui/slider.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

// ─── D-Bus contract ─────────────────────────────────────────────────────────

const DBUS_NAME = 'io.github.korrnals.BatteryThreshold';
const DBUS_PATH = '/io/github/korrnals/BatteryThreshold';
const DBUS_IFACE = 'io.github.korrnals.BatteryThreshold1';

// Generated from the same XML the daemon exports — keeps client/server in sync.
const DBUS_INTERFACE_XML = `
<node>
  <interface name="io.github.korrnals.BatteryThreshold1">
    <property name="Supported" type="b" access="read"/>
    <property name="Vendor" type="s" access="read"/>
    <property name="BatteryPath" type="s" access="read"/>
    <property name="MinStart" type="y" access="read"/>
    <property name="MaxEnd" type="y" access="read"/>
    <property name="Step" type="y" access="read"/>
    <property name="Start" type="y" access="read"/>
    <property name="End" type="y" access="read"/>
    <property name="Enabled" type="b" access="read"/>
    <method name="SetThresholds">
      <arg name="start" type="y" direction="in"/>
      <arg name="end" type="y" direction="in"/>
      <arg name="enabled" type="b" direction="in"/>
    </method>
    <method name="Refresh"/>
    <signal name="StateChanged"/>
  </interface>
</node>`;

const BatteryThresholdProxy = Gio.DBusProxy.makeProxyWrapper(DBUS_INTERFACE_XML);

// ─── Defaults / constants ───────────────────────────────────────────────────

const DEFAULT_START = 30;
const DEFAULT_END = 70;
const MIN_RANGE = 10;
const REFRESH_INTERVAL_SECONDS = 30;

// Discrete End values supported by the Xiaomi WMID EC (see prefs.js).
// The Start slider stays continuous — it's enforced in software by the
// daemon and any value is valid.
const END_VALUES = [40, 50, 60, 70, 80, 90];
const snapEnd = (pct) => END_VALUES.reduce(
    (best, v) => Math.abs(v - pct) < Math.abs(best - pct) ? v : best,
    END_VALUES[0]);

// ─── Panel indicator ────────────────────────────────────────────────────────

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, _('Battery Threshold'));

        this._extension = extension;
        this._settings = extension.getSettings();
        this._proxy = null;
        this._supported = false;
        this._refreshSourceId = 0;
        this._signalIds = [];
        // Re-entrancy guard: set while we update UI from daemon state so
        // that programmatic slider/toggle updates don't fire user-action
        // handlers and trigger a second SetThresholds call.
        this._syncing = false;

        // Panel icon — custom SVG bundled with the extension
        this._iconFile = Gio.File.new_for_path(
            `${extension.path}/icons/battery-threshold-symbolic.svg`);
        let panelGicon;
        try {
            panelGicon = Gio.icon_new_for_string(this._iconFile.get_path());
        } catch (e) {
            log(`Battery Threshold: failed to load custom icon, using fallback: ${e}`);
            panelGicon = Gio.ThemedIcon.new('battery-good-symbolic');
        }
        this._icon = new St.Icon({
            gicon: panelGicon,
            style_class: 'system-status-icon battery-threshold-icon',
        });
        this.add_child(this._icon);

        // Visibility follows show-indicator setting
        this._visibilityHandlerId = this._settings.connect(
            'changed::show-indicator',
            () => this._applyVisibility(),
        );
        this._applyVisibility();

        // Apply is now explicit: only the menu Apply item, the enable
        // toggle, and the Preferences Apply button (via `apply-trigger`)
        // push to the daemon. Editing threshold values just updates
        // GSettings; the user picks the moment of commit. This prevents
        // spinner clicks / slider drags from flooding D-Bus and stalling
        // the shell.
        this._settingsHandlerIds = [
            this._settings.connect('changed::apply-trigger',
                () => this._applyFromSettings()),
        ];

        this._buildMenu();
        this._connectProxy();
    }

    _applyVisibility() {
        this.visible = this._settings.get_boolean('show-indicator');
    }

    _buildMenu() {
        // Status row (read-only)
        this._statusItem = new PopupMenu.PopupMenuItem(
            _('Connecting to daemon…'),
            {reactive: false},
        );
        this.menu.addMenuItem(this._statusItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Enable toggle
        this._enableSwitch = new PopupMenu.PopupSwitchMenuItem(
            _('Enable Thresholds'),
            false,
        );
        this._enableSwitch.connect('toggled', (item) => {
            if (this._syncing)
                return;
            this._settings.set_boolean('enabled', item.state);
            this._applyFromSettings();
        });
        this.menu.addMenuItem(this._enableSwitch);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Start (min) slider — continuous, software-enforced by daemon
        this._startRow = this._makeSliderRow(_('Start'), 'threshold-start');
        this.menu.addMenuItem(this._startRow.item);

        // End (max) slider — snaps to discrete EC steps to match prefs
        this._endRow = this._makeSliderRow(_('End'), 'threshold-end',
            {snap: snapEnd});
        this.menu.addMenuItem(this._endRow.item);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Apply
        this._applyItem = new PopupMenu.PopupMenuItem(_('Apply'));
        this._applyItem.connect('activate', () => this._applyFromSettings());
        this.menu.addMenuItem(this._applyItem);

        // Preferences
        const prefsItem = new PopupMenu.PopupMenuItem(_('Preferences…'));
        prefsItem.connect('activate', () => this._extension.openPreferences());
        this.menu.addMenuItem(prefsItem);
    }

    _makeSliderRow(label, settingsKey, {snap} = {}) {
        const item = new PopupMenu.PopupBaseMenuItem({activate: false});

        const lbl = new St.Label({
            text: label,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'min-width: 3.5em;',
        });
        item.add_child(lbl);

        const initial = this._settings.get_int(settingsKey);
        const slider = new Slider(initial / 100);
        slider.x_expand = true;

        const valueLabel = new St.Label({
            text: `${snap ? snap(initial) : initial}%`,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'min-width: 3em; text-align: right;',
        });

        slider.connect('notify::value', () => {
            const raw = Math.round(slider.value * 100);
            const v = snap ? snap(raw) : raw;
            valueLabel.text = `${v}%`;
        });
        slider.connect('drag-end', () => {
            if (this._syncing)
                return;
            const raw = Math.round(slider.value * 100);
            const v = snap ? snap(raw) : raw;
            if (snap && slider.value !== v / 100)
                slider.value = v / 100;
            this._settings.set_int(settingsKey, v);
        });

        item.add_child(slider);
        item.add_child(valueLabel);

        return {item, slider, valueLabel};
    }

    // ─── D-Bus glue ────────────────────────────────────────────────────────

    _connectProxy() {
        new BatteryThresholdProxy(
            Gio.DBus.system,
            DBUS_NAME,
            DBUS_PATH,
            (proxy, error) => {
                if (error) {
                    this._statusItem.label.text = _('Daemon unavailable');
                    this._setControlsSensitive(false);
                    console.error(`BatteryThreshold: ${error.message}`);
                    return;
                }
                this._proxy = proxy;
                this._signalIds.push(proxy.connectSignal(
                    'StateChanged',
                    () => this._refreshFromProxy(),
                ));
                this._signalIds.push(proxy.connect(
                    'g-properties-changed',
                    () => this._refreshFromProxy(),
                ));
                this._refreshFromProxy();
                this._startPeriodicRefresh();
            },
        );
    }

    _refreshFromProxy() {
        if (!this._proxy || this._syncing)
            return;
        this._syncing = true;
        try {
            this._doRefreshFromProxy();
        } finally {
            this._syncing = false;
        }
    }

    _doRefreshFromProxy() {
        try {
            this._supported = this._proxy.Supported;
        } catch (e) {
            this._supported = false;
        }

        if (!this._supported) {
            this._statusItem.label.text = _('Not supported on this device');
            this._setControlsSensitive(false);
            this._icon.remove_style_pseudo_class('active');
            this._icon.add_style_pseudo_class('disabled');
            return;
        }
        this._icon.remove_style_pseudo_class('disabled');

        const vendor = this._proxy.Vendor || 'generic';
        const minStart = this._proxy.MinStart ?? 0;
        const maxEnd = this._proxy.MaxEnd ?? 100;
        const start = this._proxy.Start ?? 0;
        const end = this._proxy.End ?? 100;
        const enabled = this._proxy.Enabled ?? false;

        // Daemon now emulates the lower threshold in software for end-only
        // backends (xiaomi WMID, sysfs without start file), so the Start
        // slider is meaningful everywhere — always show it.
        this._startRow.item.visible = true;

        // Status line that actually tells the user what's going on.
        const live = this._readBatteryState();
        const liveSuffix = live ? ` — ${live}` : '';
        if (enabled) {
            this._statusItem.label.text =
                _('Active: %d%%–%d%% (%s)').format(start, end, vendor) + liveSuffix;
        } else {
            this._statusItem.label.text =
                _('Charge limit off (%s)').format(vendor) + liveSuffix;
        }

        this._setControlsSensitive(true);
        this._enableSwitch.setToggleState(enabled);

        // GSettings is the source of truth for *user intent*. We do NOT
        // sync daemon → settings here — that would race against an Apply
        // in flight (user picks End=90, presses Apply; before SetThresholds
        // returns, this tick reads daemon=80 and overwrites settings back
        // to 80, dragging the prefs ComboRow with it). Reconciliation
        // happens once, in _applyFromSettings's success callback, where we
        // know the daemon's reply reflects what we just sent.
        const displayStart = this._settings.get_int('threshold-start');
        const displayEnd = this._settings.get_int('threshold-end');
        this._startRow.slider.value = displayStart / 100;
        this._endRow.slider.value = displayEnd / 100;
        this._startRow.valueLabel.text = `${displayStart}%`;
        this._endRow.valueLabel.text = `${displayEnd}%`;

        // Suppress unused-var lint for minStart/maxEnd until we use them.
        void minStart; void maxEnd; void start; void end;

        if (enabled)
            this._icon.add_style_pseudo_class('active');
        else
            this._icon.remove_style_pseudo_class('active');

        // Visual cue: limit reached and laptop is running directly off AC
        // (EC bypass mode — battery is neither charging nor discharging).
        const ac = this._readAcOnline();
        const rawStatus = this._readBatteryStatusRaw();
        const limitReached = enabled && ac &&
            (rawStatus === 'Not charging' || rawStatus === 'Full');
        if (limitReached)
            this._icon.add_style_pseudo_class('checked');
        else
            this._icon.remove_style_pseudo_class('checked');

        // Xiaomi (and some other) ECs don't fire a uevent when the EC
        // stops charging, so UPower keeps reporting state=Charging and
        // the stock GNOME battery icon keeps the lightning bolt long
        // after the EC has actually engaged the limit. Nudge UPower to
        // re-read sysfs whenever the limit-reached state flips.
        if (this._lastLimitReached !== limitReached) {
            this._lastLimitReached = limitReached;
            this._pokeUPower();
        }
    }

    _setControlsSensitive(sensitive) {
        this._enableSwitch.setSensitive(sensitive);
        this._startRow.item.setSensitive(sensitive);
        this._endRow.item.setSensitive(sensitive);
        this._applyItem.setSensitive(sensitive);
    }

    _applyFromSettings() {
        if (!this._proxy || !this._supported)
            return;

        let start = this._settings.get_int('threshold-start');
        let end = this._settings.get_int('threshold-end');
        const enabled = this._settings.get_boolean('enabled');

        if (enabled && end - start < MIN_RANGE) {
            this._notify(_('Range too small: end must exceed start by at least %d%%').format(MIN_RANGE));
            return;
        }

        this._proxy.SetThresholdsRemote(start, end, enabled, (_result, error) => {
            if (error) {
                this._notify(_('Failed to apply: %s').format(error.message));
                console.error(`BatteryThreshold: ${error.message}`);
                return;
            }
            // Reconcile: if the daemon snapped our values to its supported
            // grid (e.g. End 78 → 80), pull the actual values back into
            // GSettings so the UI stops disagreeing with reality. Safe to
            // do here because we know the daemon just processed our call.
            const actualStart = this._proxy.Start ?? start;
            const actualEnd = this._proxy.End ?? end;
            if (actualStart !== start)
                this._settings.set_int('threshold-start', actualStart);
            if (actualEnd !== end)
                this._settings.set_int('threshold-end', actualEnd);
            if (enabled) {
                this._notify(_('Charge limit set to %d%%').format(actualEnd));
            } else {
                // On end-only backends (Xiaomi WMID) the EC only consults
                // the limit at the next AC plug-in event. Tell the user.
                const ac = this._readAcOnline();
                const status = this._readBatteryStatusRaw();
                if (ac && status === 'Not charging') {
                    this._notify(_('Charge limit disabled. Briefly unplug and reconnect the charger so the EC resumes charging.'));
                } else {
                    this._notify(_('Charge limit disabled'));
                }
            }
        });
    }

    // Live battery state from sysfs (sync — files are tiny and the read
    // returns instantly). Returns a short human-readable string or null.
    _readBatteryState() {
        const cap = this._readSysfsFirst('/sys/class/power_supply', /^BAT/, 'capacity');
        const status = this._readBatteryStatusRaw();
        if (cap === null && !status)
            return null;
        const capStr = cap !== null ? `${cap}%` : '?%';
        if (!status)
            return capStr;
        // Translate kernel-side strings to something more honest.
        const ac = this._readAcOnline();
        let label = status;
        if (status === 'Not charging' && ac)
            label = _('limit reached');
        else if (status === 'Full')
            label = _('full');
        else if (status === 'Charging')
            label = _('charging');
        else if (status === 'Discharging')
            label = _('on battery');
        return `${capStr} ${label}`;
    }

    _readBatteryStatusRaw() {
        return this._readSysfsFirst('/sys/class/power_supply', /^BAT/, 'status');
    }

    _readAcOnline() {
        const v = this._readSysfsFirst('/sys/class/power_supply', /^(AC|ADP)/, 'online');
        return v === '1' || v === 1;
    }

    // Ask UPower to re-read every device's state. UPower normally polls
    // every ~30s and reacts to udev events; on Xiaomi the EC silently
    // stops the charge without a uevent, so the GNOME battery icon
    // (driven by UPower) keeps showing the lightning bolt until the next
    // poll. Calling Refresh on each device makes UPower re-read sysfs
    // immediately and emit PropertiesChanged, which gnome-shell picks up.
    _pokeUPower() {
        Gio.DBus.system.call(
            'org.freedesktop.UPower',
            '/org/freedesktop/UPower',
            'org.freedesktop.UPower',
            'EnumerateDevices',
            null,
            new GLib.VariantType('(ao)'),
            Gio.DBusCallFlags.NONE, -1, null,
            (conn, res) => {
                let paths;
                try {
                    [paths] = conn.call_finish(res).deep_unpack();
                } catch (_e) {
                    return; // UPower not available
                }
                for (const p of paths) {
                    Gio.DBus.system.call(
                        'org.freedesktop.UPower', p,
                        'org.freedesktop.UPower.Device', 'Refresh',
                        null, null,
                        Gio.DBusCallFlags.NONE, -1, null,
                        () => {});
                }
            });
    }

    // Finds the first directory in `dir` matching `pattern` and returns the
    // trimmed content of `file` inside it, or null on failure.
    _readSysfsFirst(dir, pattern, file) {
        try {
            const d = Gio.File.new_for_path(dir);
            const enumerator = d.enumerate_children('standard::name',
                Gio.FileQueryInfoFlags.NONE, null);
            let info;
            while ((info = enumerator.next_file(null)) !== null) {
                const name = info.get_name();
                if (!pattern.test(name))
                    continue;
                const target = Gio.File.new_for_path(`${dir}/${name}/${file}`);
                if (!target.query_exists(null))
                    continue;
                const [ok, bytes] = target.load_contents(null);
                if (!ok)
                    continue;
                const s = new TextDecoder().decode(bytes).trim();
                return /^-?\d+$/.test(s) ? parseInt(s, 10) : s;
            }
        } catch (_e) {
            return null;
        }
        return null;
    }

    _startPeriodicRefresh() {
        // Two timers: a slow one that asks the daemon to re-read its state
        // (covers daemon-side changes), and a fast one that just re-reads
        // sysfs so the icon/status line reflect "limit reached" within a
        // few seconds of the EC stopping the charge.
        this._refreshSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            REFRESH_INTERVAL_SECONDS,
            () => {
                if (this._proxy)
                    this._proxy.RefreshRemote(() => {});
                return GLib.SOURCE_CONTINUE;
            },
        );
        this._iconTickSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            5,
            () => {
                if (this._proxy && this._supported)
                    this._refreshFromProxy();
                return GLib.SOURCE_CONTINUE;
            },
        );
    }

    _notify(message) {
        const source = new MessageTray.Source({
            title: _('Battery Threshold'),
            iconName: 'battery-good-symbolic',
        });
        Main.messageTray.add(source);
        const notification = new MessageTray.Notification({
            source,
            title: _('Battery Threshold'),
            body: message,
            isTransient: true,
        });
        source.addNotification(notification);
    }

    destroy() {
        if (this._visibilityHandlerId) {
            this._settings.disconnect(this._visibilityHandlerId);
            this._visibilityHandlerId = 0;
        }
        if (this._settingsHandlerIds) {
            for (const id of this._settingsHandlerIds)
                this._settings.disconnect(id);
            this._settingsHandlerIds = null;
        }
        if (this._pendingApplyId) {
            GLib.source_remove(this._pendingApplyId);
            this._pendingApplyId = 0;
        }
        if (this._refreshSourceId) {
            GLib.source_remove(this._refreshSourceId);
            this._refreshSourceId = 0;
        }
        if (this._iconTickSourceId) {
            GLib.source_remove(this._iconTickSourceId);
            this._iconTickSourceId = 0;
        }
        if (this._proxy) {
            for (const id of this._signalIds) {
                try {
                    if (typeof id === 'number')
                        this._proxy.disconnect(id);
                    else
                        this._proxy.disconnectSignal(id);
                } catch (_) { /* ignore */ }
            }
            this._signalIds = [];
            this._proxy = null;
        }
        super.destroy();
    }
});

// ─── Extension entry points ─────────────────────────────────────────────────

export default class BatteryThresholdExtension extends Extension {
    enable() {
        // Seed sane defaults if first run
        const settings = this.getSettings();
        if (settings.get_int('threshold-start') === 0 &&
            settings.get_int('threshold-end') === 0) {
            settings.set_int('threshold-start', DEFAULT_START);
            settings.set_int('threshold-end', DEFAULT_END);
        }

        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
