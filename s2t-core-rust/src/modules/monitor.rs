use anyhow::{Result, Context};
use evdev::{Device, Key};
use log::{info, debug, error};
use tokio::sync::mpsc;

pub enum HotkeyEvent {
    Pressed,
    Released,
    ManualPaste,
}

pub async fn run(tx: mpsc::Sender<HotkeyEvent>) -> Result<()> {
    info!("Initializing key monitor...");

    let device_path = find_keyd_device().context("Could not find keyd virtual keyboard")?;
    
    let device = Device::open(&device_path)
        .context(format!("Failed to open input device {}", device_path))?;

    info!("Monitoring device: {}", device.name().unwrap_or("Unknown"));

    let mut stream = device.into_event_stream()?;

    while let Ok(event) = stream.next_event().await {
        if let evdev::InputEventKind::Key(key) = event.kind() {
            match key {
                Key::KEY_F24 => {
                    match event.value() {
                        1 => {
                            debug!("Hotkey pressed (F24)");
                            let _ = tx.send(HotkeyEvent::Pressed).await;
                        }
                        0 => {
                            debug!("Hotkey released (F24)");
                            let _ = tx.send(HotkeyEvent::Released).await;
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }
    
    error!("Event stream ended unexpectedly");
    Ok(())
}

fn find_keyd_device() -> Option<String> {
    for i in 0..64 {
        let path = format!("/dev/input/event{}", i);
        if let Ok(device) = Device::open(&path) {
            if device.name().unwrap_or("").contains("keyd") {
                return Some(path);
            }
        }
    }
    Some("/dev/input/event24".to_string())
}
