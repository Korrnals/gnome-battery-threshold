// Xiaomi / Redmi backend via /proc/acpi/call (WMI).
//
// Xiaomi laptops (RedmiBook Pro 16 2025, etc.) expose charge limiting only
// through ACPI methods that the kernel doesn't currently surface in sysfs.
// The Xiaomi PC Manager calls the WMID.WMAA method with a fixed buffer; this
// has been reverse-engineered and documented on the Arch Wiki.
//
// Supported limits (percentage → buffer[6] byte):
//     40 → 0x08, 50 → 0x07, 60 → 0x06, 70 → 0x05, 80 → 0x01, 90 → 0x04
//
// The "enable" buffer (0xfa command) must be sent twice; the "disable" buffer
// uses the 0xfb command with a zero limit.
//
// Because there is no readback, we cache the last value we wrote.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::fs;
use tokio::sync::Mutex;
use tokio::time::sleep;
use tracing::info;

use crate::error::{BackendError, BackendResult};
use crate::vendors::{BackendInfo, Thresholds, VendorBackend};

const ACPI_CALL: &str = "/proc/acpi/call";

/// Allowed end-thresholds, in ascending order.
const ALLOWED_END: [u8; 6] = [40, 50, 60, 70, 80, 90];

fn end_to_byte(end: u8) -> Option<u8> {
    match end {
        40 => Some(0x08),
        50 => Some(0x07),
        60 => Some(0x06),
        70 => Some(0x05),
        80 => Some(0x01),
        90 => Some(0x04),
        _ => None,
    }
}

pub struct XiaomiBackend {
    info: BackendInfo,
    cache: Arc<Mutex<Thresholds>>,
}

impl XiaomiBackend {
    pub async fn new(battery: PathBuf) -> Option<Self> {
        if !std::path::Path::new(ACPI_CALL).exists() {
            return None;
        }
        Some(Self {
            info: BackendInfo {
                vendor: "xiaomi",
                battery_path: battery.to_string_lossy().into_owned(),
                min_start: 0,
                max_end: 90,
                step: 10,
            },
            cache: Arc::new(Mutex::new(Thresholds {
                start: 0,
                end: 70,
                enabled: false,
            })),
        })
    }
}

#[async_trait]
impl VendorBackend for XiaomiBackend {
    fn info(&self) -> &BackendInfo {
        &self.info
    }

    fn snap(&self, value: u8) -> u8 {
        // Snap to nearest allowed end-threshold.
        ALLOWED_END
            .iter()
            .copied()
            .min_by_key(|&v| (v as i32 - value as i32).abs())
            .unwrap_or(70)
    }

    fn is_end_only(&self) -> bool {
        true
    }

    async fn get_thresholds(&self) -> BackendResult<Thresholds> {
        Ok(*self.cache.lock().await)
    }

    async fn set_thresholds(&self, t: Thresholds) -> BackendResult<()> {
        if !t.enabled {
            // Dedup: if EC already disabled, skip the 2s sleep sequence.
            // Rapid UI drags otherwise queue up multi-second ACPI bursts
            // that block the D-Bus method and visibly freeze the shell.
            {
                let cache = self.cache.lock().await;
                if !cache.enabled {
                    info!("xiaomi: disable requested but cache already disabled, skipping ACPI writes");
                    return Ok(());
                }
            }
            // Reference script calls 0xfb 0x00 twice with a delay between
            // them; without the gap the EC silently drops the second call.
            info!("xiaomi: writing 0xfb 0x00 (no limit) #1");
            disable().await?;
            sleep(EC_DELAY).await;
            info!("xiaomi: writing 0xfb 0x00 (no limit) #2");
            disable().await?;
            // NOTE: On this hardware (RedmiBook Pro 16 2025, kernel 6.19)
            // the EC consults the limit register only on a physical AC
            // plug-in transition. Writing "no limit" while it is already
            // in `Not charging` state does NOT resume charging —
            // confirmed empirically: unbinding/rebinding the platform
            // `ac` driver does not propagate to the EC either. Document
            // this in the user-facing notification rather than trying to
            // simulate a plug event from software.
            let mut cache = self.cache.lock().await;
            cache.enabled = false;
            cache.start = 0;
            info!("xiaomi: charge limit disabled (EC will resume charging at next physical plug-in event)");
            return Ok(());
        }

        // Xiaomi exposes only an end-threshold; start is informational and
        // always 0. Do NOT snap `start` — snap() targets ALLOWED_END (40..80)
        // and would yield start=40 for any requested start<45.
        let end = self.snap(t.end);
        let byte = end_to_byte(end).ok_or(BackendError::OutOfRange {
            value: end,
            min: 40,
            max: 90,
        })?;

        // Dedup: if EC already enabled at the same end value, skip.
        {
            let cache = self.cache.lock().await;
            if cache.enabled && cache.end == end {
                info!("xiaomi: cache already enabled at {end}%, skipping ACPI writes");
                return Ok(());
            }
        }

        // Sequence per Xiaomi PC Manager / Arch Wiki reference:
        //   0xfb <limit>; sleep 1; 0xfa 0x00; sleep 1; 0xfa 0x00
        // The sleeps are required — without them the EC drops calls and
        // the limit never engages (the WMAA method itself still returns
        // a success-looking response, which is why it appears to work).
        info!("xiaomi: writing 0xfb 0x{byte:02x} (limit={end}%)");
        write_acpi_call(&build_set_buffer(byte)).await?;
        sleep(EC_DELAY).await;
        info!("xiaomi: writing 0xfa 0x00 (enable) #1");
        write_acpi_call(&build_enable_buffer()).await?;
        sleep(EC_DELAY).await;
        info!("xiaomi: writing 0xfa 0x00 (enable) #2");
        write_acpi_call(&build_enable_buffer()).await?;

        *self.cache.lock().await = Thresholds {
            start: 0,
            end,
            enabled: true,
        };
        info!("xiaomi: charge limit engaged at {end}%");
        Ok(())
    }
}

/// EC needs a beat between WMAA calls; back-to-back writes get dropped.
const EC_DELAY: Duration = Duration::from_millis(1000);

async fn disable() -> BackendResult<()> {
    // 0xfb with zero limit → unlimited charging.
    write_acpi_call(&build_set_buffer(0x00)).await
}

async fn write_acpi_call(cmd: &str) -> BackendResult<()> {
    fs::write(ACPI_CALL, cmd)
        .await
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::PermissionDenied => BackendError::PermissionDenied,
            _ => BackendError::Io(e),
        })
}

/// 0xfb — set charge limit. `limit_byte` is the value in buffer[6].
fn build_set_buffer(limit_byte: u8) -> String {
    build_buffer(0xfb, limit_byte)
}

/// 0xfa — enable charge limiting. Limit byte unused (0x00).
fn build_enable_buffer() -> String {
    build_buffer(0xfa, 0x00)
}

fn build_buffer(command_byte: u8, limit_byte: u8) -> String {
    // 32-byte payload, only bytes 0..7 are meaningful.
    let mut buf = String::from("\\_SB.PC00.WMID.WMAA 0x0 0x1 { 0x00");
    buf.push_str(&format!(" 0x{:02x}", command_byte));
    buf.push_str(" 0x00 0x10 0x02 0x00");
    buf.push_str(&format!(" 0x{:02x}", limit_byte));
    for _ in 7..32 {
        buf.push_str(" 0x00");
    }
    buf.push_str(" }");
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snap_returns_supported_steps() {
        let b = pollster();
        assert_eq!(b.snap(42), 40);
        assert_eq!(b.snap(55), 50);
        assert_eq!(b.snap(67), 70);
        assert_eq!(b.snap(73), 70);
        assert_eq!(b.snap(86), 90);
        assert_eq!(b.snap(100), 90);
        assert_eq!(b.snap(0), 40);
    }

    #[test]
    fn buffers_have_correct_length() {
        // The WMAA call takes two leading args (0x0, 0x1) followed by a
        // 32-byte buffer in braces. Total = 2 + 32 = 34 byte literals.
        let set = build_set_buffer(0x05);
        let enable = build_enable_buffer();
        assert_eq!(set.matches("0x").count(), 34);
        assert_eq!(enable.matches("0x").count(), 34);
        // Buffer payload (between braces) must be exactly 32 bytes.
        let payload = set.split('{').nth(1).unwrap().trim_end_matches(|c: char| c.is_whitespace() || c == '}');
        assert_eq!(payload.split_whitespace().count(), 32);
    }

    /// Build a backend instance without filesystem checks for unit tests.
    fn pollster() -> XiaomiBackend {
        XiaomiBackend {
            info: BackendInfo {
                vendor: "xiaomi",
                battery_path: String::new(),
                min_start: 0,
                max_end: 90,
                step: 10,
            },
            cache: Arc::new(Mutex::new(Thresholds::default())),
        }
    }
}
