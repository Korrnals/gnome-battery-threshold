// D-Bus interface for the daemon.
//
// Interface: io.github.korrnals.BatteryThreshold1
// Object:    /io/github/korrnals/BatteryThreshold
// Bus name:  io.github.korrnals.BatteryThreshold (system bus)

use tracing::{debug, info};
use zbus::{fdo, interface, Connection, SignalContext};

use crate::state::SharedState;
use crate::vendors::Thresholds;

const DBUS_PATH: &str = "/io/github/korrnals/BatteryThreshold";

pub struct BatteryThresholdService {
    state: SharedState,
}

impl BatteryThresholdService {
    pub fn new(state: SharedState) -> Self {
        Self { state }
    }
}

#[interface(name = "io.github.korrnals.BatteryThreshold1")]
impl BatteryThresholdService {
    // ─── Properties ────────────────────────────────────────────────────

    #[zbus(property)]
    async fn supported(&self) -> bool {
        self.state.is_supported().await
    }

    #[zbus(property)]
    async fn vendor(&self) -> String {
        self.state.vendor_name().await
    }

    #[zbus(property)]
    async fn battery_path(&self) -> String {
        self.state
            .with_backend(|b| b.info().battery_path.clone())
            .await
            .unwrap_or_default()
    }

    #[zbus(property)]
    async fn min_start(&self) -> u8 {
        self.state
            .with_backend(|b| b.info().min_start)
            .await
            .unwrap_or(0)
    }

    #[zbus(property)]
    async fn max_end(&self) -> u8 {
        self.state
            .with_backend(|b| b.info().max_end)
            .await
            .unwrap_or(100)
    }

    #[zbus(property)]
    async fn step(&self) -> u8 {
        self.state
            .with_backend(|b| b.info().step)
            .await
            .unwrap_or(1)
    }

    #[zbus(property)]
    async fn start(&self) -> u8 {
        let Some(backend) = self.state.backend().await else {
            return 0;
        };
        backend.get_thresholds().await.map(|t| t.start).unwrap_or(0)
    }

    #[zbus(property)]
    async fn end(&self) -> u8 {
        let Some(backend) = self.state.backend().await else {
            return 100;
        };
        backend.get_thresholds().await.map(|t| t.end).unwrap_or(100)
    }

    #[zbus(property)]
    async fn enabled(&self) -> bool {
        let Some(backend) = self.state.backend().await else {
            return false;
        };
        backend
            .get_thresholds()
            .await
            .map(|t| t.enabled)
            .unwrap_or(false)
    }

    // ─── Methods ───────────────────────────────────────────────────────

    /// Apply thresholds. The daemon snaps `start`/`end` to whatever the
    /// active backend supports; clients can read back the actual values via
    /// the corresponding properties or the StateChanged signal.
    async fn set_thresholds(
        &self,
        start: u8,
        end: u8,
        enabled: bool,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        let backend = self
            .state
            .backend()
            .await
            .ok_or_else(|| fdo::Error::NotSupported("no supported backend on this device".into()))?;

        let snapped = Thresholds {
            start: backend.snap(start),
            end: backend.snap(end),
            enabled,
        };

        info!(
            "SetThresholds requested={start}-{end} enabled={enabled} snapped={}-{}",
            snapped.start, snapped.end
        );

        backend.set_thresholds(snapped).await?;
        self.state.persist(snapped).await;
        Self::state_changed(&ctxt).await?;
        Ok(())
    }

    /// Re-read current state from hardware (forces a property refresh).
    async fn refresh(&self, #[zbus(signal_context)] ctxt: SignalContext<'_>) -> fdo::Result<()> {
        debug!("Refresh requested");
        Self::state_changed(&ctxt).await?;
        Ok(())
    }

    // ─── Signals ───────────────────────────────────────────────────────

    #[zbus(signal)]
    async fn state_changed(ctxt: &SignalContext<'_>) -> zbus::Result<()>;
}

/// Emit a manual StateChanged signal from outside the interface impl.
pub async fn emit_state_changed(connection: &Connection) -> zbus::Result<()> {
    let ctxt = SignalContext::new(connection, DBUS_PATH)?;
    BatteryThresholdService::state_changed(&ctxt).await
}
