mod modules;

use anyhow::Result;
use log::{info, error};
use tokio::sync::mpsc;
use crate::modules::monitor::HotkeyEvent;
use crate::modules::audio::AudioRecorder;
use crate::modules::cloud::GoogleCloudClient;
use crate::modules::x11::X11Context;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize rustls crypto provider
    let _ = rustls::crypto::ring::default_provider().install_default();

    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    info!("Starting S2T Rust Core (HTTP/3 Streaming)...");

    let (hotkey_tx, mut hotkey_rx) = mpsc::channel(10);
    
    // 1. Start Monitor
    let hotkey_tx_monitor = hotkey_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = modules::monitor::run(hotkey_tx_monitor).await {
            error!("Monitor error: {}", e);
        }
    });

    let mut recorder = AudioRecorder::new();
    let x11 = Arc::new(X11Context::new(hotkey_tx.clone())?);
    
    // Configuration
    let project_id = "poetic-emblem-494722-v2".to_string();
    let location = "europe-west4".to_string();

    let client = Arc::new(GoogleCloudClient::new(
        project_id,
        location,
        "_".to_string(),
    ));

    let is_streaming = Arc::new(AtomicBool::new(false));
    let mut current_audio_tx: Option<mpsc::Sender<Vec<u8>>> = None;

    // 2. Main Event Loop
    info!("Ready. Press F24 to record, Alt+V to paste last transcription.");
    while let Some(event) = hotkey_rx.recv().await {
        match event {
            HotkeyEvent::Pressed => {
                if is_streaming.load(Ordering::SeqCst) {
                    info!("Stream already active, ignoring press.");
                    continue;
                }
                
                info!("Hotkey pressed. Starting stream...");
                let start_time = std::time::Instant::now();
                let (audio_tx, audio_rx) = mpsc::channel::<Vec<u8>>(100);
                current_audio_tx = Some(audio_tx.clone());
                is_streaming.store(true, Ordering::SeqCst);
                
                let client_clone = client.clone();
                let x11_clone = x11.clone();
                let is_streaming_clone = is_streaming.clone();
                
                let sample_rate = match recorder.start(audio_tx) {
                    Ok(sr) => sr,
                    Err(e) => {
                        error!("Failed to start recorder: {}", e);
                        is_streaming.store(false, Ordering::SeqCst);
                        continue;
                    }
                };

                tokio::spawn(async move {
                    match client_clone.stream_audio(audio_rx, sample_rate, is_streaming_clone.clone()).await {
                        Ok(text) => {
                            let elapsed = start_time.elapsed();
                            if !text.is_empty() {
                                info!("Transcription received in {:?}: {}", elapsed, text);
                                x11_clone.set_last_text(text.clone()).await;
                                // Automatic insertion (fast swap/paste/restore)
                                if let Err(e) = x11_clone.paste_secondary_fast(text).await {
                                    error!("Failed to auto-paste text: {}", e);
                                } else {
                                    info!("Auto-paste completed successfully.");
                                }
                            } else {
                                info!("Empty transcription received in {:?}.", elapsed);
                            }
                        }
                        Err(e) => error!("Cloud streaming error after {:?}: {}", start_time.elapsed(), e),
                    }
                    is_streaming_clone.store(false, Ordering::SeqCst);
                });
            }
            HotkeyEvent::Released => {
                if !is_streaming.load(Ordering::SeqCst) {
                    continue;
                }
                info!("Hotkey released. Stopping stream...");
                let _ = recorder.stop();
                // Explicitly drop the sender to close the channel and the gRPC stream
                current_audio_tx.take();
            }
            HotkeyEvent::ManualPaste => {
                info!("Manual paste requested (Alt+V)...");
                let x11_clone = x11.clone();
                tokio::spawn(async move {
                    if let Err(e) = x11_clone.paste_secondary_fast("".to_string()).await {
                        error!("Failed to manual-paste text: {}", e);
                    }
                });
            }
        }
    }

    Ok(())
}
