// Shared daemon state.
//
// Holds the active vendor backend and the user's intended thresholds. For
// end-only backends (Xiaomi WMID, sysfs implementations without
// charge_control_start_threshold) the daemon emulates the lower threshold
// in software via `reconcile`: when the battery rises to `end` the EC limit
// is engaged; when it drops to `start` the limit is released so the laptop
// can charge back up. For two-threshold backends the EC handles hysteresis
// itself and `reconcile` simply pushes the intent through.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::fs;
use tokio::sync::RwLock;
use tracing::{debug, info, warn};

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
    intent: RwLock<Thresholds>,
    hw_engaged: RwLock<bool>,
}

impl SharedState {
    pub async fn detect() -> BackendResult<Self> {
        let backend = detect_backend().await?;
        Ok(Self(Arc::new(Inner {
            backend: RwLock::new(backend),
            intent: RwLock::new(Thresholds::default()),
            hw_engaged: RwLock::new(false),
        })))
    }

    pub fn unsupported(reason: String) -> Self {
        tracing::warn!("running in unsupported mode: {reason}");
        Self(Arc::new(Inner {
            backend: RwLock::new(None),
            intent: RwLock::new(Thresholds::default()),
            hw_engaged: RwLock::new(false),
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

    pub async fn intent(&self) -> Thresholds {
        *self.0.intent.read().await
    }

    pub async fn is_end_only(&self) -> bool {
        self.with_backend(|b| b.is_end_only())
            .await
            .unwrap_or(false)
    }

    /// Replace user intent and immediately reconcile to hardware.
    /// Returns the snapped intent that was stored.
    pub async fn set_intent(&self, t: Thresholds) -> BackendResult<Thresholds> {
        let snapped = match self.backend().await {
            Some(b) => Thresholds {
                start: t.start.min(95),
                end: b.snap(t.end),
                enabled: t.enabled,
            },
            None => t,
        };
        *self.0.intent.write().await = snapped;
        self.reconcile().await?;
        self.persist(snapped).await;
        Ok(snapped)
    }

    /// Apply persisted thresholds on daemon startup.
    pub async fn apply_persisted(&self) -> BackendResult<()> {
        if self.backend().await.is_none() {
            return Ok(());
        }
        let persisted = read_state().await.unwrap_or_default();
        let intent = Thresholds {
            start: persisted.start,
            end: persisted.end,
            enabled: persisted.enabled,
        };
        *self.0.intent.write().await = intent;
        self.reconcile().await
    }

    /// Bring the EC state in line with user intent and current battery
    /// capacity. Safe to call from any task; idempotent.
    pub async fn reconcile(&self) -> BackendResult<()> {
        let Some(backend) = self.backend().await else {
            return Ok(());
        };
        let intent = self.intent().await;

        // Disabled, or two-threshold backend: push intent straight through.
        if !intent.enabled || !backend.is_end_only() {
            backend.set_thresholds(intent).await?;
            *self.0.hw_engaged.write().await = intent.enabled;
            return Ok(());
        }

        // End-only + enabled → software hysteresis.
        let capacity = read_capacity(&backend.info().battery_path).await;
        let engaged = *self.0.hw_engaged.read().await;
        let start = intent.start;
        let end = intent.end;

        let want_engaged = match capacity {
            Some(c) if c >= end => true,
            Some(c) if c <= start => false,
            // Inside the band, or capacity unknown: hold current state,
            // defaulting to engaged so we never accidentally let the
            // battery climb past the limit on first run.
            Some(_) => engaged,
            None => true,
        };

        if want_engaged && !engaged {
            info!(
                "hysteresis: capacity={:?}% ≥ end={}%, engaging EC limit",
                capacity, end
            );
            backend
                .set_thresholds(Thresholds {
                    start: 0,
                    end,
                    enabled: true,
                })
                .await?;
            *self.0.hw_engaged.write().await = true;
        } else if !want_engaged && engaged {
            info!(
                "hysteresis: capacity={:?}% ≤ start={}%, releasing EC limit to recharge",
                capacity, start
            );
            backend
                .set_thresholds(Thresholds {
                    start: 0,
                    end,
                    enabled: false,
                })
                .await?;
            *self.0.hw_engaged.write().await = false;
        } else if want_engaged {
            // Re-assert periodically: cheap, and recovers if the EC forgets
            // after suspend/resume.
            debug!("hysteresis: re-asserting EC limit at {}%", end);
            backend
                .set_thresholds(Thresholds {
                    start: 0,
                    end,
                    enabled: true,
                })
                .await?;
        }
        Ok(())
    }

    async fn persist(&self, t: Thresholds) {
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

async fn read_capacity(battery_path: &str) -> Option<u8> {
    let p = PathBuf::from(battery_path).join("capacity");
    let raw = fs::read_to_string(&p).await.ok()?;
    raw.trim().parse::<u8>().ok()
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
