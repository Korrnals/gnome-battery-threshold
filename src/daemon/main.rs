// battery-thresholdd — D-Bus daemon for laptop battery charge thresholds.
//
// Copyright (C) 2026 Korrnals
// SPDX-License-Identifier: GPL-3.0-or-later

mod battery;
mod dbus_service;
mod error;
mod state;
mod vendors;

use std::time::Duration;

use tokio::signal::unix::{signal, SignalKind};
use tracing::{error, info};
use tracing_subscriber::EnvFilter;
use zbus::ConnectionBuilder;

use crate::dbus_service::BatteryThresholdService;
use crate::state::SharedState;

const DBUS_NAME: &str = "io.github.korrnals.BatteryThreshold";
const DBUS_PATH: &str = "/io/github/korrnals/BatteryThreshold";

type DynError = Box<dyn std::error::Error + Send + Sync + 'static>;

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<(), DynError> {
    init_tracing();

    info!("battery-thresholdd {} starting", env!("CARGO_PKG_VERSION"));

    // Detect hardware and initialize shared state
    let state = match SharedState::detect().await {
        Ok(s) => s,
        Err(e) => {
            error!("Hardware detection failed: {e}");
            // Continue anyway with an unsupported state — the extension
            // will still get a useful response.
            SharedState::unsupported(e.to_string())
        }
    };

    info!("Detected vendor: {}", state.vendor_name().await);

    // Apply persisted state on startup (so reboots restore thresholds)
    if let Err(e) = state.apply_persisted().await {
        error!("Failed to apply persisted thresholds: {e}");
    }

    let service = BatteryThresholdService::new(state.clone());

    let connection = ConnectionBuilder::system()?
        .name(DBUS_NAME)?
        .serve_at(DBUS_PATH, service)?
        .build()
        .await?;

    info!("D-Bus service registered at {DBUS_PATH}");

    // Software hysteresis worker: re-evaluates the EC limit against the
    // current battery capacity every 30s. No-op for two-threshold backends
    // (EC handles it) but essential for Xiaomi and other end-only devices.
    let state_for_worker = state.clone();
    let conn_for_worker = connection.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        // Skip the immediate first tick; apply_persisted already reconciled.
        interval.tick().await;
        loop {
            interval.tick().await;
            if let Err(e) = state_for_worker.reconcile().await {
                tracing::warn!("reconcile failed: {e}");
            }
            if let Err(e) = dbus_service::emit_state_changed(&conn_for_worker).await {
                tracing::debug!("state-changed emit failed: {e}");
            }
        }
    });

    wait_for_shutdown().await;
    info!("Shutting down");
    Ok(())
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .with_writer(std::io::stderr)
        .init();
}

async fn wait_for_shutdown() {
    let mut sigterm = signal(SignalKind::terminate()).expect("install SIGTERM");
    let mut sigint = signal(SignalKind::interrupt()).expect("install SIGINT");
    tokio::select! {
        _ = sigterm.recv() => info!("Received SIGTERM"),
        _ = sigint.recv() => info!("Received SIGINT"),
    }
}
