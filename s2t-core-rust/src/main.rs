mod modules;

use anyhow::Result;
use crate::modules::audio::AudioRecorder;
use crate::modules::cloud::{build_provider, RuntimeConfig};
use crate::modules::monitor::HotkeyEvent;
use crate::modules::x11::X11Context;
use log::{error, info};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    info!("Starting S2T Rust Core (HTTP/3 Streaming)...");

    let runtime_cfg = RuntimeConfig::from_env()?;
    let provider = build_provider(&runtime_cfg)?;
    info!("Using transcribe provider: {:?}", provider.kind());

    let (hotkey_tx, mut hotkey_rx) = mpsc::channel(10);

    let hotkey_tx_monitor = hotkey_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = modules::monitor::run(hotkey_tx_monitor).await {
            error!("Monitor error: {}", e);
        }
    });

    let mut recorder = AudioRecorder::new();
    let x11 = Arc::new(X11Context::new(hotkey_tx.clone())?);

    let is_streaming = Arc::new(AtomicBool::new(false));
    let mut current_audio_tx: Option<mpsc::Sender<Vec<u8>>> = None;

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

                let provider_clone = provider.clone();
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
                    match provider_clone
                        .stream_audio(audio_rx, sample_rate, is_streaming_clone.clone())
                        .await
                    {
                        Ok(text) => {
                            let elapsed = start_time.elapsed();
                            if !text.is_empty() {
                                info!("Transcription received in {:?}: {}", elapsed, text);
                                x11_clone.set_last_text(text.clone()).await;
                                if let Err(e) = x11_clone.paste_secondary_fast(text).await {
                                    error!("Failed to auto-paste text: {}", e);
                                } else {
                                    info!("Auto-paste completed successfully.");
                                }
                            } else {
                                info!("Empty transcription received in {:?}.", elapsed);
                            }
                        }
                        Err(e) => error!(
                            "Provider streaming error after {:?}: {:#}",
                            start_time.elapsed(),
                            e
                        ),
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
