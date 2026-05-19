// Error types for the battery-thresholdd daemon.

use std::io;

use thiserror::Error;

/// All errors that can occur while talking to vendor backends.
#[derive(Debug, Error)]
pub enum BackendError {
    #[error("no battery devices found in /sys/class/power_supply")]
    NoBattery,

    #[error("vendor {0:?} is not supported on this host")]
    UnsupportedVendor(String),

    #[error("requested value {value}% is outside the supported range {min}-{max}")]
    OutOfRange { value: u8, min: u8, max: u8 },

    #[error("requested range invalid: start {start} must be < end {end}")]
    InvalidRange { start: u8, end: u8 },

    #[error("required kernel interface missing: {0}")]
    InterfaceMissing(String),

    #[error("permission denied — daemon must run as root")]
    PermissionDenied,

    #[error("I/O error: {0}")]
    Io(#[from] io::Error),

    #[error("external tool {tool} failed: {message}")]
    ExternalTool { tool: String, message: String },
}

impl From<BackendError> for zbus::fdo::Error {
    fn from(err: BackendError) -> Self {
        match err {
            BackendError::NoBattery => zbus::fdo::Error::Failed(err.to_string()),
            BackendError::UnsupportedVendor(_) => zbus::fdo::Error::NotSupported(err.to_string()),
            BackendError::OutOfRange { .. } | BackendError::InvalidRange { .. } => {
                zbus::fdo::Error::InvalidArgs(err.to_string())
            }
            BackendError::PermissionDenied => zbus::fdo::Error::AccessDenied(err.to_string()),
            BackendError::InterfaceMissing(_) => zbus::fdo::Error::Failed(err.to_string()),
            BackendError::Io(_) => zbus::fdo::Error::IOError(err.to_string()),
            BackendError::ExternalTool { .. } => zbus::fdo::Error::Failed(err.to_string()),
        }
    }
}

pub type BackendResult<T> = Result<T, BackendError>;
