#![deny(unsafe_code)]
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process;
use serde::{Serialize, Deserialize};
use zbus::{Connection, SignalContext};
use zbus::fdo::{Error, Result};

// Константы
const SYSFS_POWER: &str = "/sys/class/power_supply";
const POLKIT_ACTION: &str = "com.Korrnals.battery-threshold.set";

// Структура для D-Bus сервиса
#[derive(Debug)]
struct BatteryThreshold {
    connection: Connection,
}

#[derive(Serialize, Deserialize, Debug)]
struct BatteryInfo {
    supported: bool,
    battery: Option<String>,
    path: Option<String>,
    sysfs: Option<std::collections::HashMap<String, bool>>,
    vendors: Option<std::collections::HashMap<String, bool>>,
    reason: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
struct Thresholds {
    start: Option<u8>,
    end: Option<u8>,
}

#[zbus::interface(name = "org.gnome.BatteryThreshold")]
impl BatteryThreshold {
    // Проверка поддержки порогов
    async fn check_support(&self) -> Result<BatteryInfo> {
        let batteries = find_batteries()?;
        if batteries.is_empty() {
            return Ok(BatteryInfo {
                supported: false,
                battery: None,
                path: None,
                sysfs: None,
                vendors: None,
                reason: Some("No batteries found".to_string()),
            });
        }
        
        for bat in batteries {
            let support = check_sysfs_support(&bat);
            let vendors = check_vendor_support();
            
            if support.values().any(|&v| v) || vendors.values().any(|&v| v) {
                return Ok(BatteryInfo {
                    supported: true,
                    battery: Some(bat.file_name().unwrap().to_string_lossy().into_owned()),
                    path: Some(bat.to_string_lossy().into_owned()),
                    sysfs: Some(support),
                    vendors: Some(vendors),
                    reason: None,
                });
            }
        }
        
        Ok(BatteryInfo {
            supported: false,
            battery: None,
            path: None,
            sysfs: None,
            vendors: None,
            reason: Some("No threshold control interface found".to_string()),
        })
    }
    
    // Получение текущих порогов
    async fn get_thresholds(&self) -> Result<Thresholds> {
        let batteries = find_batteries()?;
        if batteries.is_empty() {
            return Err(Error::Failed("No batteries found".into()));
        }
        
        let thresholds = get_thresholds(&batteries[0])?;
        Ok(thresholds)
    }
    
    // Установка порогов
    async fn set_thresholds(
        &self,
        start: u8,
        end: u8,
        enabled: bool,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> Result<()> {
        if start >= end {
            return Err(Error::InvalidArgs("Start must be less than end".into()));
        }
        if end - start < 10 {
            return Err(Error::InvalidArgs("Range must be at least 10%".into()));
        }
        
        let batteries = find_batteries()?;
        if batteries.is_empty() {
            return Err(Error::Failed("No batteries found".into()));
        }
        
        if !enabled {
            reset_thresholds(&batteries[0])?;
        } else {
            set_thresholds(&batteries[0], start, end)?;
        }
        
        // Отправка сигнала об изменении
        Self::thresholds_changed(&ctxt).await?;
        Ok(())
    }
    
    // Сигнал об изменении порогов
    #[zbus(signal)]
    async fn thresholds_changed(ctxt: &SignalContext<'_>) -> Result<()>;
}

// Поиск батарей
fn find_batteries() -> Result<Vec<PathBuf>> {
    let mut batteries = Vec::new();
    if !Path::new(SYSFS_POWER).exists() {
        return Ok(batteries);
    }
    
    for entry in fs::read_dir(SYSFS_POWER)? {
        let entry = entry?;
        let type_path = entry.path().join("type");
        if type_path.exists() {
            let mut file = File::open(type_path)?;
            let mut contents = String::new();
            file.read_to_string(&mut contents)?;
            if contents.trim().eq_ignore_ascii_case("battery") {
                batteries.push(entry.path());
            }
        }
    }
    
    Ok(batteries)
}

// Проверка поддержки sysfs
fn check_sysfs_support(battery_path: &Path) -> std::collections::HashMap<String, bool> {
    let mut support = std::collections::HashMap::new();
    let files = [
        "charge_control_start_threshold",
        "charge_control_end_threshold",
        "charge_control_limit",
        "charge_control_limit_max",
    ];
    
    for file in files {
        let path = battery_path.join(file);
        support.insert(file.to_string(), path.exists());
    }
    
    support
}

// Проверка поддержки вендоров
fn check_vendor_support() -> std::collections::HashMap<String, bool> {
    let mut vendors = std::collections::HashMap::new();
    
    // ASUS, Xiaomi, Framework, Dell, Huawei
    let asus_path = Path::new("/sys/class/power_supply/BAT0/charge_control_end_threshold");
    vendors.insert("asus".to_string(), asus_path.exists());
    vendors.insert("xiaomi".to_string(), asus_path.exists());
    vendors.insert("framework".to_string(), asus_path.exists());
    vendors.insert("dell".to_string(), asus_path.exists());
    vendors.insert("huawei".to_string(), asus_path.exists());
    
    // Lenovo/ThinkPad
    vendors.insert("thinkpad_smapi".to_string(), Path::new("/sys/devices/platform/smapi").exists());
    vendors.insert("thinkpad_acpi_call".to_string(), Path::new("/proc/acpi/call").exists());
    
    // Samsung
    vendors.insert("samsung".to_string(), Path::new("/sys/devices/platform/samsung/battery_life_extender").exists());
    
    // Sony
    vendors.insert("sony".to_string(), Path::new("/sys/devices/platform/sony-laptop/battery_care_limiter").exists());
    
    vendors
}

// Получение текущих порогов
fn get_thresholds(battery_path: &Path) -> Result<Thresholds> {
    let mut result = Thresholds { start: None, end: None };
    
    let start_path = battery_path.join("charge_control_start_threshold");
    let end_path = battery_path.join("charge_control_end_threshold");
    let limit_path = battery_path.join("charge_control_limit");
    
    if start_path.exists() {
        let mut file = File::open(start_path)?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        result.start = contents.trim().parse().ok();
    }
    
    if end_path.exists() {
        let mut file = File::open(end_path)?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        result.end = contents.trim().parse().ok();
    }
    
    // Fallback to charge_control_limit
    if result.end.is_none() && limit_path.exists() {
        let mut file = File::open(limit_path)?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        result.end = contents.trim().parse().ok();
    }
    
    Ok(result)
}

// Установка порогов
fn set_thresholds(battery_path: &Path, start: u8, end: u8) -> Result<()> {
    let start_path = battery_path.join("charge_control_start_threshold");
    let end_path = battery_path.join("charge_control_end_threshold");
    let limit_path = battery_path.join("charge_control_limit");
    
    if start_path.exists() {
        let mut file = File::create(start_path)?;
        file.write_all(start.to_string().as_bytes())?;
    }
    
    if end_path.exists() {
        let mut file = File::create(end_path)?;
        file.write_all(end.to_string().as_bytes())?;
    } else if limit_path.exists() {
        // Fallback для систем с одним порогом
        let mut file = File::create(limit_path)?;
        file.write_all(end.to_string().as_bytes())?;
    }
    
    Ok(())
}

// Сброс порогов
fn reset_thresholds(battery_path: &Path) -> Result<()> {
    set_thresholds(battery_path, 0, 100)
}

// Основная функция
#[tokio::main]
async fn main() -> Result<()> {
    // Проверка прав
    if !nix::unistd::Uid::effective().is_root() {
        eprintln!("This service must be run as root");
        process::exit(1);
    }
    
    // Создание D-Bus соединения
    let connection = Connection::system().await?;
    let battery_threshold = BatteryThreshold { connection: connection.clone() };
    
    // Регистрация сервиса
    connection.object_server().at("/org/gnome/BatteryThreshold", battery_threshold).await?;
    
    // Запрос имени
    connection.request_name("org.gnome.BatteryThreshold").await?;
    
    println!("Battery Threshold D-Bus service started");
    
    // Основной цикл
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
    }
}