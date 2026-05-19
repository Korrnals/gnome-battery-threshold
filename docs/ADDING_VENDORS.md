# Adding Support for a New Vendor

The vendor abstraction is designed so that adding a new laptop family
takes one new file and one line of detection code. Here is the recipe.

## 1. Decide what the hardware exposes

You will normally find your laptop falls into one of three buckets:

1. **Standard sysfs** (`charge_control_*_threshold`). You don't need a new
   backend — the existing `SysfsBackend` already handles you. Just verify
   detection picks it up.
2. **`tpacpi-bat` / `tp_smapi`**. Use `ThinkPadBackend` as a template.
3. **Custom ACPI method** via `/proc/acpi/call`. Use `XiaomiBackend` as a
   template.

If your hardware does something completely different (e.g. requires an
ioctl), you'll need a custom implementation.

## 2. Implement the backend

Create `src/daemon/vendors/<vendor>.rs`:

```rust
use async_trait::async_trait;
use std::path::PathBuf;

use crate::error::BackendResult;
use crate::vendors::{BackendInfo, Thresholds, VendorBackend};

pub struct MyVendorBackend {
    info: BackendInfo,
    // … any state you need
}

impl MyVendorBackend {
    pub async fn new(battery: PathBuf) -> Option<Self> {
        // Probe for required interfaces. Return `None` if not available.
        Some(Self {
            info: BackendInfo {
                vendor: "myvendor",
                battery_path: battery.to_string_lossy().into_owned(),
                min_start: 0,
                max_end: 100,
                step: 1,        // continuous slider
                                // (or e.g. 10 for snap-to-10-percent steps)
            },
            // …
        })
    }
}

#[async_trait]
impl VendorBackend for MyVendorBackend {
    fn info(&self) -> &BackendInfo { &self.info }

    async fn get_thresholds(&self) -> BackendResult<Thresholds> {
        // Read current state from hardware.
        todo!()
    }

    async fn set_thresholds(&self, t: Thresholds) -> BackendResult<()> {
        // Apply. If your hardware uses discrete steps, prefer overriding
        // `snap` and rely on the daemon to call `set_thresholds` with
        // already-snapped values.
        todo!()
    }
}
```

## 3. Register detection

In `src/daemon/vendors/mod.rs`, add:

```rust
pub mod myvendor;

pub async fn detect_backend() -> BackendResult<Option<Arc<dyn VendorBackend>>> {
    // … existing rules

    if dmi.matches_myvendor() {
        if let Some(b) = myvendor::MyVendorBackend::new(battery.clone()).await {
            return Ok(Some(Arc::new(b)));
        }
    }

    // … fallback to sysfs as before
}
```

Add the corresponding `matches_myvendor()` helper to `battery.rs`:

```rust
impl DmiInfo {
    pub fn matches_myvendor(&self) -> bool {
        self.sys_vendor.to_lowercase().contains("myvendor")
    }
}
```

## 4. Tests

Add unit tests for any pure-function logic — value snapping, buffer
encoding, parsing of tool output, etc. These should not touch the
filesystem so they can run in CI:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snap_picks_nearest_step() {
        let backend = MyVendorBackend { /* in-memory */ };
        assert_eq!(backend.snap(73), 70);
    }
}
```

## 5. Documentation

Create `docs/vendors/<vendor>.md` describing the interface in plain
English so the next maintainer doesn't have to re-discover it.

## 6. Sanity check

```bash
make lint test
sudo make daemon-dev
# In another terminal:
busctl --system call io.github.korrnals.BatteryThreshold \
    /io/github/korrnals/BatteryThreshold \
    io.github.korrnals.BatteryThreshold1 \
    SetThresholds yyb 30 70 true
```

If the values appear back through `busctl get-property`, you're done.
Open a PR with a description of the model you tested on.
