// ThinkPad backend.
//
// Modern ThinkPads (Linux kernel ≥ 5.17) expose the standard sysfs interface,
// in which case the generic `SysfsBackend` is sufficient. This module exists
// for older models that need `tpacpi-bat` or `tp_smapi`.
//
// For now we delegate to `SysfsBackend` when possible and only fall through
// to vendor-specific code paths if sysfs is unavailable.

use std::path::PathBuf;

use async_trait::async_trait;
use tokio::process::Command;
use tracing::debug;

use crate::error::{BackendError, BackendResult};
use crate::vendors::{sysfs::SysfsBackend, BackendInfo, Thresholds, VendorBackend};

pub struct ThinkPadBackend {
    inner: Inner,
    info: BackendInfo,
}

enum Inner {
    Sysfs(SysfsBackend),
    Tpacpi,
}

impl ThinkPadBackend {
    pub async fn new(battery: PathBuf) -> Option<Self> {
        if let Some(s) = SysfsBackend::new(battery.clone()).await {
            return Some(Self {
                info: BackendInfo {
                    vendor: "thinkpad",
                    battery_path: s.info().battery_path.clone(),
                    min_start: 0,
                    max_end: 100,
                    step: 1,
                },
                inner: Inner::Sysfs(s),
            });
        }
        if which::tpacpi_available().await {
            return Some(Self {
                info: BackendInfo {
                    vendor: "thinkpad",
                    battery_path: battery.to_string_lossy().into_owned(),
                    min_start: 0,
                    max_end: 100,
                    step: 1,
                },
                inner: Inner::Tpacpi,
            });
        }
        None
    }
}

#[async_trait]
impl VendorBackend for ThinkPadBackend {
    fn info(&self) -> &BackendInfo {
        &self.info
    }

    async fn get_thresholds(&self) -> BackendResult<Thresholds> {
        match &self.inner {
            Inner::Sysfs(s) => s.get_thresholds().await,
            Inner::Tpacpi => tpacpi_get().await,
        }
    }

    async fn set_thresholds(&self, t: Thresholds) -> BackendResult<()> {
        match &self.inner {
            Inner::Sysfs(s) => s.set_thresholds(t).await,
            Inner::Tpacpi => tpacpi_set(t).await,
        }
    }
}

#[allow(dead_code)]
async fn tpacpi_get() -> BackendResult<Thresholds> {
    let start = tpacpi_query("ST").await?;
    let end = tpacpi_query("SP").await?;
    Ok(Thresholds {
        start,
        end,
        enabled: !(start == 0 && end == 100),
    })
}

async fn tpacpi_set(t: Thresholds) -> BackendResult<()> {
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

    tpacpi_write("ST", start).await?;
    tpacpi_write("SP", end).await?;
    debug!("thinkpad/tpacpi: thresholds applied {start}-{end}");
    Ok(())
}

#[allow(dead_code)]
async fn tpacpi_query(field: &str) -> BackendResult<u8> {
    let out = Command::new("tpacpi-bat")
        .args(["-g", field, "1"])
        .output()
        .await
        .map_err(|e| BackendError::ExternalTool {
            tool: "tpacpi-bat".into(),
            message: e.to_string(),
        })?;
    if !out.status.success() {
        return Err(BackendError::ExternalTool {
            tool: "tpacpi-bat".into(),
            message: String::from_utf8_lossy(&out.stderr).into_owned(),
        });
    }
    let text = String::from_utf8_lossy(&out.stdout);
    text.split_whitespace()
        .last()
        .and_then(|s| s.parse::<u8>().ok())
        .ok_or_else(|| BackendError::ExternalTool {
            tool: "tpacpi-bat".into(),
            message: format!("could not parse output: {text}"),
        })
}

async fn tpacpi_write(field: &str, value: u8) -> BackendResult<()> {
    let out = Command::new("tpacpi-bat")
        .args(["-s", field, "1", &value.to_string()])
        .output()
        .await
        .map_err(|e| BackendError::ExternalTool {
            tool: "tpacpi-bat".into(),
            message: e.to_string(),
        })?;
    if !out.status.success() {
        return Err(BackendError::ExternalTool {
            tool: "tpacpi-bat".into(),
            message: String::from_utf8_lossy(&out.stderr).into_owned(),
        });
    }
    Ok(())
}

mod which {
    use tokio::process::Command;

    pub async fn tpacpi_available() -> bool {
        Command::new("which")
            .arg("tpacpi-bat")
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
}
