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

        // Auto-apply when gsettings change (e.g. user edited Preferences).
        // Debounced so SpinRow's per-click changes don't fire a dozen
        // SetThresholds calls.
        this._pendingApplyId = 0;
        const scheduleApply = () => {
            if (this._syncing)
                return;
            if (this._pendingApplyId)
                GLib.source_remove(this._pendingApplyId);
            this._pendingApplyId = GLib.timeout_add(
                GLib.PRIORITY_DEFAULT, 400, () => {
                    this._pendingApplyId = 0;
                    this._applyFromSettings();
                    return GLib.SOURCE_REMOVE;
                });
        };
        this._settingsHandlerIds = [
            this._settings.connect('changed::threshold-start', scheduleApply),
            this._settings.connect('changed::threshold-end', scheduleApply),
            this._settings.connect('changed::enabled', scheduleApply),
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

        // Start (min) slider
        this._startRow = this._makeSliderRow(_('Start'), 'threshold-start');
        this.menu.addMenuItem(this._startRow.item);

        // End (max) slider
        this._endRow = this._makeSliderRow(_('End'), 'threshold-end');
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

    _makeSliderRow(label, settingsKey) {
        const item = new PopupMenu.PopupBaseMenuItem({activate: false});

        const lbl = new St.Label({
            text: label,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'min-width: 3.5em;',
        });
        item.add_child(lbl);

        const slider = new Slider(this._settings.get_int(settingsKey) / 100);
        slider.x_expand = true;

        const valueLabel = new St.Label({
            text: `${this._settings.get_int(settingsKey)}%`,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'min-width: 3em; text-align: right;',
        });

        slider.connect('notify::value', () => {
            const v = Math.round(slider.value * 100);
            valueLabel.text = `${v}%`;
        });
        slider.connect('drag-end', () => {
            if (this._syncing)
                return;
            this._settings.set_int(settingsKey, Math.round(slider.value * 100));
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
        if (enabled) {
            this._statusItem.label.text =
                _('Active: %d%%–%d%% (%s)').format(start, end, vendor);
        } else {
            this._statusItem.label.text =
                _('Charge limit off (%s)').format(vendor);
        }

        this._setControlsSensitive(true);
        this._enableSwitch.setToggleState(enabled);

        // Daemon properties now reflect user intent (the daemon stores
        // start/end as intent and emulates the lower threshold in software
        // for end-only backends). Sync gsettings if the daemon snapped end.
        const settingsEnd = this._settings.get_int('threshold-end');
        if (settingsEnd !== end && enabled)
            this._settings.set_int('threshold-end', end);
        const settingsStart = this._settings.get_int('threshold-start');
        if (settingsStart !== start && enabled)
            this._settings.set_int('threshold-start', start);

        const displayStart = this._settings.get_int('threshold-start');
        const displayEnd = this._settings.get_int('threshold-end');
        this._startRow.slider.value = displayStart / 100;
        this._endRow.slider.value = displayEnd / 100;
        this._startRow.valueLabel.text = `${displayStart}%`;
        this._endRow.valueLabel.text = `${displayEnd}%`;

        // Suppress unused-var lint for minStart/maxEnd until we use them.
        void minStart; void maxEnd;

        if (enabled)
            this._icon.add_style_pseudo_class('active');
        else
            this._icon.remove_style_pseudo_class('active');
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
            // Daemon emitted PropertiesChanged — GDBusProxy will refresh
            // its cache and fire `g-properties-changed`, which calls
            // `_refreshFromProxy`. We also notify the user so Apply has
            // visible feedback even if the limit doesn't kick in until the
            // next charge cycle.
            if (enabled)
                this._notify(_('Charge limit set to %d%%').format(end));
            else
                this._notify(_('Charge limit disabled'));
        });
    }

    _startPeriodicRefresh() {
        this._refreshSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            REFRESH_INTERVAL_SECONDS,
            () => {
                if (this._proxy)
                    this._proxy.RefreshRemote(() => {});
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
