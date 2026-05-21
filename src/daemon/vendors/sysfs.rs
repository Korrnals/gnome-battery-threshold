// Standard sysfs backend.
//
// Used by ASUS, Dell, Framework, Huawei, MSI, recent Lenovo and several
// other vendors. The kernel exposes:
//
//   /sys/class/power_supply/BATx/charge_control_start_threshold
//   /sys/class/power_supply/BATx/charge_control_end_threshold

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use tokio::fs;
use tracing::debug;

use crate::error::{BackendError, BackendResult};
use crate::vendors::{BackendInfo, Thresholds, VendorBackend};

const START_FILE: &str = "charge_control_start_threshold";
const END_FILE: &str = "charge_control_end_threshold";

pub struct SysfsBackend {
    info: BackendInfo,
    start_path: PathBuf,
    end_path: PathBuf,
    has_start: bool,
}

impl SysfsBackend {
    pub async fn new(battery: PathBuf) -> Option<Self> {
        let end_path = battery.join(END_FILE);
        if !end_path.exists() {
            return None;
        }
        let start_path = battery.join(START_FILE);
        let has_start = start_path.exists();

        Some(Self {
            info: BackendInfo {
                vendor: "sysfs",
                battery_path: battery.to_string_lossy().into_owned(),
                min_start: 0,
                max_end: 100,
                step: 1,
            },
            start_path,
            end_path,
            has_start,
        })
    }
}

#[async_trait]
impl VendorBackend for SysfsBackend {
    fn info(&self) -> &BackendInfo {
        &self.info
    }

    fn is_end_only(&self) -> bool {
        !self.has_start
    }

    async fn get_thresholds(&self) -> BackendResult<Thresholds> {
        let end: u8 = read_percent(&self.end_path).await?;
        let start: u8 = if self.has_start {
            read_percent(&self.start_path).await?
        } else {
            0
        };
        // sysfs has no separate "enabled" concept — anything other than 0/100
        // is considered enabled.
        let enabled = !(start == 0 && end == 100);
        Ok(Thresholds {
            start,
            end,
            enabled,
        })
    }

    async fn set_thresholds(&self, t: Thresholds) -> BackendResult<()> {
        let (start, end) = if t.enabled {
            if t.start >= t.end {
                return Err(BackendError::InvalidRange {
                    start: t.start,
                    end: t.end,
                });
            }
            (t.start, t.end)
        } else {
            (0u8, 100u8)
        };

        // Always write end first; some kernels reject inconsistent intermediate
        // states (start > end) if we write in the opposite order.
        write_percent(&self.end_path, end).await?;
        if self.has_start {
            write_percent(&self.start_path, start).await?;
        }
        debug!("sysfs thresholds applied: {start}-{end}");
        Ok(())
    }
}

async fn read_percent(path: &Path) -> BackendResult<u8> {
    let raw = fs::read_to_string(path).await?;
    raw.trim().parse::<u8>().map_err(|_| {
        BackendError::InterfaceMissing(format!("invalid percent value in {}", path.display()))
    })
}

async fn write_percent(path: &Path, value: u8) -> BackendResult<()> {
    fs::write(path, format!("{value}\n"))
        .await
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::PermissionDenied => BackendError::PermissionDenied,
            _ => BackendError::Io(e),
        })
}
