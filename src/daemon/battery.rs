// Battery discovery utilities.

use std::path::{Path, PathBuf};

use tokio::fs;

use crate::error::{BackendError, BackendResult};

const SYSFS_POWER_SUPPLY: &str = "/sys/class/power_supply";

/// Discover the first battery device under /sys/class/power_supply.
///
/// Returns the absolute path to the battery directory.
pub async fn primary_battery() -> BackendResult<PathBuf> {
    let mut entries = fs::read_dir(SYSFS_POWER_SUPPLY).await?;
    while let Some(entry) = entries.next_entry().await? {
        let type_file = entry.path().join("type");
        if !type_file.exists() {
            continue;
        }
        let kind = fs::read_to_string(&type_file).await?;
        if kind.trim().eq_ignore_ascii_case("Battery") {
            return Ok(entry.path());
        }
    }
    Err(BackendError::NoBattery)
}

/// Read DMI vendor / product information (best-effort).
pub async fn dmi_info() -> DmiInfo {
    DmiInfo {
        sys_vendor: read_dmi_field("sys_vendor").await,
        product_name: read_dmi_field("product_name").await,
    }
}

async fn read_dmi_field(field: &str) -> String {
    let path = Path::new("/sys/class/dmi/id").join(field);
    fs::read_to_string(&path)
        .await
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

#[derive(Clone, Debug, Default)]
pub struct DmiInfo {
    pub sys_vendor: String,
    pub product_name: String,
}

impl DmiInfo {
    pub fn matches_xiaomi(&self) -> bool {
        let v = self.sys_vendor.to_lowercase();
        let p = self.product_name.to_lowercase();
        v.contains("xiaomi") || p.contains("redmi") || p.contains("xiaomi")
    }

    pub fn matches_thinkpad(&self) -> bool {
        let v = self.sys_vendor.to_lowercase();
        let p = self.product_name.to_lowercase();
        v.contains("lenovo") && p.contains("thinkpad")
    }
}
