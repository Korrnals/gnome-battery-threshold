import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';

import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

const BUS_NAME = 'org.gnome.BatteryThreshold';
const OBJECT_PATH = '/org/gnome/BatteryThreshold';
const INTERFACE_NAME = 'org.gnome.BatteryThreshold';

// UUID расширения
const EXTENSION_UUID = 'battery-threshold@Korrnals.dev';

let _extension = null;

// Vendor-specific threshold configurations
const VENDOR_CONFIGS = {
    'xiaomi': {
        thresholds: [40, 50, 60, 70, 80],
        singleThreshold: true,
        label: 'Charge Limit'
    },
    'asus': {
        min: 0, max: 100,
        label: 'Charge Limit'
    },
    'thinkpad': {
        min: 0, max: 100,
        label: 'Charge Thresholds'
    },
    'framework': {
        min: 0, max: 100,
        label: 'Charge Limit'
    }
};
const BatteryThresholdProxy = GObject.registerClass(
class BatteryThresholdProxy extends Gio.DBusProxy {
    _init() {
        super._init({
            g_connection: Gio.DBus.system,
            g_interface_name: INTERFACE_NAME,
            g_object_path: OBJECT_PATH,
            g_bus_type: Gio.BusType.SYSTEM,
            g_name: BUS_NAME,
        });
    }
    
    async checkSupport() {
        try {
            let result = await this.call(
                'check_support',
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );
            return JSON.parse(result.deep_unpack()[0]);
        } catch (e) {
            logError(e, 'Failed to check battery threshold support');
            return { supported: false, reason: e.message };
        }
    }
    
    async getThresholds() {
        try {
            let result = await this.call(
                'get_thresholds',
                null,
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );
            return JSON.parse(result.deep_unpack()[0]);
        } catch (e) {
            logError(e, 'Failed to get battery thresholds');
            return { start: 0, end: 100 };
        }
    }
    
    async setThresholds(start, end, enabled) {
        try {
            await this.call(
                'set_thresholds',
                new GLib.Variant('(yyb)', [start, end, enabled]),
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );
            return true;
        } catch (e) {
            logError(e, 'Failed to set battery thresholds');
            return false;
        }
    }
});

// Поддерживаемые пороги для устройств с фиксированными значениями
const FIXED_THRESHOLDS = {
    'xiaomi': [40, 50, 60, 70, 80]
};

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.0, _('Battery Threshold'));
        
        this._extension = extension;
        this._settings = extension.getSettings();
        this._thresholdSupported = false;
        this._currentEnd = 100;
        this._currentStart = 0;
        this._vendorType = null;  // 'xiaomi', 'asus', 'thinkpad', etc.
        
        // Инициализация D-Bus прокси
        this._dbusProxy = new BatteryThresholdProxy();
        this._dbusProxy.init_async(GLib.PRIORITY_DEFAULT, null, (proxy, res) => {
            try {
                proxy.init_finish(res);
                this._dbusProxy = proxy;
                this._checkSupport();
            } catch (e) {
                logError(e, 'Failed to initialize D-Bus proxy');
                this._statusItem.label.text = _('D-Bus service not available');
                this._updateUI();
            }
        });
        
        // Icon
        this._icon = new St.Icon({
            icon_name: 'battery-full-symbolic',
            style_class: 'system-status-icon'
        });
        this.add_child(this._icon);
        
        // Menu items
        this._buildMenu();
        
        // Check support and update
        this._checkSupport();
        this._updateUI();
        
        // Monitor changes
        this._settingsChangedId = this._settings.connect('changed', () => this._updateUI());
        
        // Periodic refresh
        this._refreshTimeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 30, () => {
            this._readCurrentThresholds();
            return GLib.SOURCE_CONTINUE;
        });
    }
    
    _buildMenu() {
        // Status section
        this._statusItem = new PopupMenu.PopupMenuItem(_('Checking support...'), {reactive: false});
        this.menu.addMenuItem(this._statusItem);
        
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        // Enable/Disable toggle
        this._enableToggle = new PopupMenu.PopupSwitchMenuItem(_('Enable Thresholds'), false);
        this._enableToggle.connect('toggled', (item) => {
            this._settings.set_boolean('enabled', item.state);
            this._applyThresholds();
        });
        this.menu.addMenuItem(this._enableToggle);
        
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        // Vendor-specific threshold selector (for devices with fixed values)
        this._fixedThresholdItem = new PopupMenu.PopupSubMenuMenuItem(_('Charge Limit: 70%'));
        this._fixedThresholdItems = [];
        this._fixedThresholdItem.hide();
        this.menu.addMenuItem(this._fixedThresholdItem);
        
        // Standard sliders (for devices with continuous range)
        // Start threshold slider
        this._startSliderItem = new PopupMenu.PopupBaseMenuItem({activate: false});
        this._startSliderItem.add_child(new St.Label({text: _('Min:'), y_align: Clutter.ActorAlign.CENTER}));
        this._startSlider = new Slider(0, 100, 30);
        this._startSlider.connect('drag-end', () => {
            this._settings.set_int('threshold-start', this._startSlider.value);
        });
        this._startSliderItem.add_child(this._startSlider);
        this._startValueLabel = new St.Label({text: '30%', y_align: Clutter.ActorAlign.CENTER, style: 'min-width: 3em; text-align: right;'});
        this._startSliderItem.add_child(this._startValueLabel);
        this.menu.addMenuItem(this._startSliderItem);
        
        // End threshold slider
        this._endSliderItem = new PopupMenu.PopupBaseMenuItem({activate: false});
        this._endSliderItem.add_child(new St.Label({text: _('Max:'), y_align: Clutter.ActorAlign.CENTER}));
        this._endSlider = new Slider(0, 100, 70);
        this._endSlider.connect('drag-end', () => {
            this._settings.set_int('threshold-end', this._endSlider.value);
        });
        this._endSliderItem.add_child(this._endSlider);
        this._endValueLabel = new St.Label({text: '70%', y_align: Clutter.ActorAlign.CENTER, style: 'min-width: 3em; text-align: right;'});
        this._endSliderItem.add_child(this._endValueLabel);
        this.menu.addMenuItem(this._endSliderItem);
        
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        
        // Apply button
        this._applyItem = new PopupMenu.PopupMenuItem(_('Apply Now'));
        this._applyItem.connect('activate', () => this._applyThresholds());
        this.menu.addMenuItem(this._applyItem);
        
        // Settings button
        this._settingsItem = new PopupMenu.PopupMenuItem(_('Settings'));
        this._settingsItem.connect('activate', () => {
            if (this._extension && this._extension.openPreferences) {
                this._extension.openPreferences();
            }
        });
        this.menu.addMenuItem(this._settingsItem);
    }
    
    async _checkSupport() {
        try {
            let result = await this._dbusProxy.checkSupport();
            this._thresholdSupported = result.supported;
            
            // Определяем тип устройства
            if (result.vendors) {
                if (result.vendors.xiaomi) {
                    this._vendorType = 'xiaomi';
                    this._statusItem.label.text = _('Xiaomi acpi_call detected');
                } else if (result.vendors.asus) {
                    this._vendorType = 'asus';
                    this._statusItem.label.text = _('ASUS charge control detected');
                } else if (result.vendors.thinkpad) {
                    this._vendorType = 'thinkpad';
                    this._statusItem.label.text = _('ThinkPad charge control detected');
                } else if (result.vendors.framework) {
                    this._vendorType = 'framework';
                    this._statusItem.label.text = _('Framework charge control detected');
                } else if (result.supported) {
                    this._statusItem.label.text = _('Threshold control available');
                } else {
                    this._statusItem.label.text = result.reason || _('Threshold control not available');
                }
            } else if (result.supported) {
                this._statusItem.label.text = _('Threshold control available');
            } else {
                this._statusItem.label.text = result.reason || _('Threshold control not available');
            }
            
            // Setup fixed thresholds UI if needed
            if (this._vendorType && FIXED_THRESHOLDS[this._vendorType]) {
                this._setupFixedThresholds(this._vendorType);
            }
            
            if (result.supported) {
                this._readCurrentThresholds();
            }
        } catch (e) {
            this._statusItem.label.text = _('Error: ') + e.message;
            this._thresholdSupported = false;
        }
        this._updateUI();
    }
    
    _setupFixedThresholds(vendor) {
        // Clear existing items
        this._fixedThresholdItem.menu.removeAll();
        this._fixedThresholdItems = [];
        
        let thresholds = FIXED_THRESHOLDS[vendor] || [];
        for (let threshold of thresholds) {
            let item = new PopupMenu.PopupMenuItem(_(`${threshold}%`));
            item.connect('activate', () => {
                this._settings.set_int('threshold-end', threshold);
                this._settings.set_int('threshold-start', 0);
                this._applyThresholds();
            });
            this._fixedThresholdItem.menu.addMenuItem(item);
            this._fixedThresholdItems.push({threshold, item});
        }
    }
    
    async _readCurrentThresholds() {
        if (!this._thresholdSupported) return;
        try {
            let result = await this._dbusProxy.getThresholds();
            this._currentStart = result.start || 0;
            this._currentEnd = result.end || 100;
            this._updateIcon();
        } catch (e) {
            logError(e, 'Error reading thresholds');
        }
    }
    
    async _applyThresholds() {
        if (!this._thresholdSupported) {
            this._showNotification(_('Threshold control not available on this device'));
            return;
        }
        
        let enabled = this._settings.get_boolean('enabled');
        let start = this._settings.get_int('threshold-start');
        let end = this._settings.get_int('threshold-end');
        
        // Validate only for devices with continuous range
        if (enabled && !this._vendorType) {
            if (start >= end) {
                this._showNotification(_('Invalid thresholds: Min must be less than Max'));
                return;
            }
            if (end - start < 10) {
                this._showNotification(_('Range too small: Min and Max should differ by at least 10%'));
                return;
            }
        }
        
        // Показать индикатор загрузки
        this._applyItem.label.text = _('Applying...');
        this._applyItem.setSensitive(false);
        
        try {
            let success = await this._dbusProxy.setThresholds(start, end, enabled);
            if (success) {
                if (this._vendorType) {
                    let config = VENDOR_CONFIGS[this._vendorType] || {};
                    let label = config.label || _('Charge Limit');
                    this._showNotification(_(`${label} set to ${end}%`));
                } else {
                    this._showNotification(_('Thresholds applied: ') + start + '% - ' + end + '%');
                }
                this._readCurrentThresholds();
            } else {
                this._showNotification(_('Failed to apply thresholds'));
            }
        } catch (e) {
            this._showNotification(_('Error: ') + e.message);
        } finally {
            this._applyItem.label.text = _('Apply Now');
            this._applyItem.setSensitive(true);
        }
    }
    
    _updateUI() {
        let enabled = this._settings.get_boolean('enabled');
        let start = this._settings.get_int('threshold-start');
        let end = this._settings.get_int('threshold-end');
        
        this._enableToggle.setToggleState(enabled);
        
        if (this._vendorType && FIXED_THRESHOLDS[this._vendorType]) {
            // Для устройств с фиксированными порогами показываем селектор
            this._fixedThresholdItem.show();
            this._startSliderItem.hide();
            this._endSliderItem.hide();
            
            // Обновляем текст селектора
            let config = VENDOR_CONFIGS[this._vendorType] || {};
            let label = config.label || _('Charge Limit');
            this._fixedThresholdItem.label.text = _(label + ': ') + end + '%';
            
            // Подсвечиваем активный пункт
            for (let {threshold, item} of this._fixedThresholdItems) {
                if (threshold === end) {
                    item.setOrnament(PopupMenu.Ornament.CHECK);
                } else {
                    item.setOrnament(PopupMenu.Ornament.NONE);
                }
            }
            
            this._fixedThresholdItem.setSensitive(this._thresholdSupported && enabled);
        } else {
            // Для других устройств показываем слайдеры
            this._fixedThresholdItem.hide();
            this._startSliderItem.show();
            this._endSliderItem.show();
            
            this._startSlider.value = start;
            this._endSlider.value = end;
            this._startValueLabel.text = start + '%';
            this._endValueLabel.text = end + '%';
            
            this._startSliderItem.setSensitive(this._thresholdSupported);
            this._endSliderItem.setSensitive(this._thresholdSupported);
        }
        
        this._enableToggle.setSensitive(this._thresholdSupported);
        this._applyItem.setSensitive(this._thresholdSupported);
        
        this._updateIcon();
    }
    
    _updateIcon() {
        if (!this._thresholdSupported) {
            this._icon.icon_name = 'battery-missing-symbolic';
            return;
        }
        let enabled = this._settings.get_boolean('enabled');
        if (enabled) {
            this._icon.icon_name = 'battery-full-charged-symbolic';
        } else {
            this._icon.icon_name = 'battery-full-symbolic';
        }
    }
    
    _showNotification(message) {
        let source = new MessageTray.Source({
            title: _('Battery Threshold'),
            iconName: 'battery-full-symbolic'
        });
        Main.messageTray.add(source);
        
        let notification = new MessageTray.Notification({
            source: source,
            title: _('Battery Threshold'),
            body: message,
            isTransient: true
        });
        
        notification.connect('activated', () => {
            if (this._extension && this._extension.openPreferences) {
                this._extension.openPreferences();
            }
        });
        
        source.addNotification(notification);
    }
    
    // Логирование ошибок
    logError(error, context) {
        log(`BatteryThreshold [ERROR] ${context}: ${error.message}`);
        if (error.stack) {
            log(error.stack);
        }
    }
    
    destroy() {
        if (this._settingsChangedId) {
            this._settings.disconnect(this._settingsChangedId);
            this._settingsChangedId = null;
        }
        if (this._refreshTimeout) {
            GLib.source_remove(this._refreshTimeout);
            this._refreshTimeout = null;
        }
        super.destroy();
    }
});

const Slider = GObject.registerClass({
    Signals: {
        'drag-end': {}
    }
}, class Slider extends St.DrawingArea {
    _init(min, max, value) {
        super._init({
            style_class: 'bts-slider',
            reactive: true,
            can_focus: true,
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
            height: 24
        });
        
        this._min = min;
        this._max = max;
        this._value = value;
        this._dragging = false;
        
        this.connect('button-press-event', this._onButtonPress.bind(this));
        this.connect('motion-event', this._onMotionEvent.bind(this));
        this.connect('button-release-event', this._onButtonRelease.bind(this));
        this.connect('scroll-event', this._onScrollEvent.bind(this));
        this.connect('key-press-event', this._onKeyPress.bind(this));
    }
    
    get value() {
        return this._value;
    }
    
    set value(v) {
        this._value = Math.max(this._min, Math.min(this._max, v));
        this.queue_repaint();
    }
    
    vfunc_repaint() {
        let cr = this.get_context();
        let width = this.width;
        let height = this.height;
        let radius = height / 2;
        
        // Background
        cr.setSourceRGBA(0.5, 0.5, 0.5, 0.3);
        cr.arc(radius, radius, radius - 2, Math.PI / 2, 3 * Math.PI / 2);
        cr.arc(width - radius, radius, radius - 2, 3 * Math.PI / 2, Math.PI / 2);
        cr.closePath();
        cr.fill();
        
        // Fill
        let fraction = (this._value - this._min) / (this._max - this._min);
        let fillWidth = radius * 2 + (width - radius * 2) * fraction;
        
        cr.setSourceRGBA(0.2, 0.8, 0.2, 1.0);
        cr.arc(radius, radius, radius - 2, Math.PI / 2, 3 * Math.PI / 2);
        cr.arc(fillWidth - radius, radius, radius - 2, 3 * Math.PI / 2, Math.PI / 2);
        cr.closePath();
        cr.fill();
        
        cr.$dispose();
    }
    
    _onButtonPress(actor, event) {
        this._dragging = true;
        this._updateValueFromEvent(event);
        return Clutter.EVENT_STOP;
    }
    
    _onMotionEvent(actor, event) {
        if (this._dragging) {
            this._updateValueFromEvent(event);
        }
        return Clutter.EVENT_STOP;
    }
    
    _onButtonRelease(actor, event) {
        if (this._dragging) {
            this._dragging = false;
            this.emit('drag-end');
        }
        return Clutter.EVENT_STOP;
    }
    
    _onScrollEvent(actor, event) {
        let direction = event.get_scroll_direction();
        if (direction === Clutter.ScrollDirection.UP) {
            this.value = this._value + 1;
        } else if (direction === Clutter.ScrollDirection.DOWN) {
            this.value = this._value - 1;
        }
        this.emit('drag-end');
        return Clutter.EVENT_STOP;
    }
    
    _onKeyPress(actor, event) {
        let key = event.get_key_symbol();
        if (key === Clutter.KEY_Left || key === Clutter.KEY_Down) {
            this.value = this._value - 1;
            this.emit('drag-end');
            return Clutter.EVENT_STOP;
        } else if (key === Clutter.KEY_Right || key === Clutter.KEY_Up) {
            this.value = this._value + 1;
            this.emit('drag-end');
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }
    
    _updateValueFromEvent(event) {
        let [x, y] = event.get_coords();
        let width = this.width;
        let fraction = Math.max(0, Math.min(1, x / width));
        this.value = Math.round(this._min + fraction * (this._max - this._min));
    }
});

export default class BatteryThresholdExtension extends Extension {
    enable() {
        _extension = this;
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }
    
    disable() {
        this._indicator.destroy();
        this._indicator = null;
        _extension = null;
    }
}