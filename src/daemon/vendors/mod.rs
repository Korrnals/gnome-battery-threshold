// Vendor abstraction layer.
//
// Every supported laptop family implements `VendorBackend`. The daemon picks
// the best available backend at startup based on hardware detection. The
// extension UI doesn't know — or care — which backend is in use; it sees the
// uniform `start/end` slider model.
//
// Vendors with discrete steps (e.g. Xiaomi: 40/50/60/70/80%) snap incoming
// values transparently. Reading back returns the snapped value, so the UI
// stays in sync.

use std::sync::Arc;

use async_trait::async_trait;

use crate::battery::{dmi_info, primary_battery};
use crate::error::BackendResult;

pub mod sysfs;
pub mod thinkpad;
pub mod xiaomi;

/// Capabilities and current state reported by a backend.
#[derive(Clone, Debug)]
pub struct BackendInfo {
    pub vendor: &'static str,
    pub battery_path: String,
    pub min_start: u8,
    pub max_end: u8,
    /// Granularity step. 1 means "continuous"; 10 means values snap to 10s; etc.
    pub step: u8,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Thresholds {
    pub start: u8,
    pub end: u8,
    pub enabled: bool,
}

#[async_trait]
pub trait VendorBackend: Send + Sync {
    /// Static metadata about this backend.
    fn info(&self) -> &BackendInfo;

    /// Read current thresholds from the hardware. May return cached values
    /// for backends that don't expose readback (e.g. Xiaomi).
    async fn get_thresholds(&self) -> BackendResult<Thresholds>;

    /// Apply thresholds. `enabled = false` resets to the kernel defaults
    /// (0/100 or equivalent).
    async fn set_thresholds(&self, t: Thresholds) -> BackendResult<()>;

    /// Snap arbitrary user input to a value this hardware accepts.
    /// Default implementation rounds to the backend's `step`.
    fn snap(&self, value: u8) -> u8 {
        let info = self.info();
        let step = info.step.max(1);
        let snapped = ((value as u32 + step as u32 / 2) / step as u32) * step as u32;
        (snapped as u8).clamp(info.min_start, info.max_end)
    }

    /// True when the hardware only supports an upper (stop-charge) threshold.
    /// The daemon emulates the lower threshold in software for such backends
    /// by toggling the EC limit based on the current battery capacity.
    fn is_end_only(&self) -> bool {
        false
    }
}

/// Detect the best backend for this host, in priority order.
///
/// Selection rules:
/// 1. Xiaomi/Redmi with /proc/acpi/call → Xiaomi backend.
/// 2. ThinkPad with tpacpi-bat or /proc/acpi/call → ThinkPad backend.
/// 3. Standard sysfs charge_control_* → Sysfs backend.
/// 4. Otherwise → None (unsupported).
pub async fn detect_backend() -> BackendResult<Option<Arc<dyn VendorBackend>>> {
    let battery = primary_battery().await?;
    let dmi = dmi_info().await;

    // 1. Xiaomi
    if dmi.matches_xiaomi() && std::path::Path::new("/proc/acpi/call").exists() {
        if let Some(b) = xiaomi::XiaomiBackend::new(battery.clone()).await {
            return Ok(Some(Arc::new(b)));
        }
    }

    // 2. ThinkPad
    if dmi.matches_thinkpad() {
        if let Some(b) = thinkpad::ThinkPadBackend::new(battery.clone()).await {
            return Ok(Some(Arc::new(b)));
        }
    }

    // 3. Standard sysfs
    if let Some(b) = sysfs::SysfsBackend::new(battery.clone()).await {
        return Ok(Some(Arc::new(b)));
    }

    Ok(None)
}
