// Shared daemon state.
//
// Holds the active vendor backend behind an Arc<Mutex<_>> and persists
// user-configured thresholds to /var/lib/battery-thresholdd/state.json so
// that a systemd unit can re-apply them on boot.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::fs;
use tokio::sync::RwLock;
use tracing::warn;

use crate::error::BackendResult;
use crate::vendors::{detect_backend, Thresholds, VendorBackend};

const STATE_DIR: &str = "/var/lib/battery-thresholdd";
const STATE_FILE: &str = "/var/lib/battery-thresholdd/state.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct PersistedState {
    enabled: bool,
    start: u8,
    end: u8,
}

#[derive(Clone)]
pub struct SharedState(Arc<Inner>);

struct Inner {
    backend: RwLock<Option<Arc<dyn VendorBackend>>>,
}

impl SharedState {
    pub async fn detect() -> BackendResult<Self> {
        let backend = detect_backend().await?;
        Ok(Self(Arc::new(Inner {
            backend: RwLock::new(backend),
        })))
    }

    pub fn unsupported(reason: String) -> Self {
        // Reason is logged on construction; we don't keep it around since
        // the daemon exposes `vendor == "unsupported"` via D-Bus instead.
        tracing::warn!("running in unsupported mode: {reason}");
        Self(Arc::new(Inner {
            backend: RwLock::new(None),
        }))
    }

    pub async fn is_supported(&self) -> bool {
        self.0.backend.read().await.is_some()
    }

    pub async fn vendor_name(&self) -> String {
        if let Some(b) = self.0.backend.read().await.as_ref() {
            b.info().vendor.to_string()
        } else {
            "unsupported".to_string()
        }
    }

    pub async fn with_backend<F, T>(&self, f: F) -> Option<T>
    where
        F: FnOnce(&dyn VendorBackend) -> T,
    {
        self.0.backend.read().await.as_ref().map(|b| f(b.as_ref()))
    }

    pub async fn backend(&self) -> Option<Arc<dyn VendorBackend>> {
        self.0.backend.read().await.clone()
    }

    /// Apply the last-known thresholds. Called on daemon startup.
    pub async fn apply_persisted(&self) -> BackendResult<()> {
        let Some(backend) = self.backend().await else {
            return Ok(());
        };
        let persisted = read_state().await.unwrap_or_default();
        if !persisted.enabled {
            return Ok(());
        }
        backend
            .set_thresholds(Thresholds {
                start: persisted.start,
                end: persisted.end,
                enabled: true,
            })
            .await
    }

    /// Persist the given thresholds. Errors are logged but not returned —
    /// failing to write state is non-fatal for the running daemon.
    pub async fn persist(&self, t: Thresholds) {
        let state = PersistedState {
            enabled: t.enabled,
            start: t.start,
            end: t.end,
        };
        if let Err(e) = write_state(&state).await {
            warn!("failed to persist state: {e}");
        }
    }
}

async fn read_state() -> std::io::Result<PersistedState> {
    let raw = fs::read_to_string(STATE_FILE).await?;
    serde_json::from_str(&raw).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

async fn write_state(state: &PersistedState) -> std::io::Result<()> {
    let dir = PathBuf::from(STATE_DIR);
    if !dir.exists() {
        fs::create_dir_all(&dir).await?;
    }
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    fs::write(STATE_FILE, json).await
}
