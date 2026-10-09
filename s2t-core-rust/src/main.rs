mod modules;

use crate::modules::audio::AudioRecorder;
use crate::modules::cloud::{
    build_provider, RuntimeConfig, TranscribeProvider, TranscriptionEvent,
};
use crate::modules::monitor::HotkeyEvent;
use crate::modules::x11::X11Context;
use anyhow::Result;
use log::{debug, error, info};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::Duration;

fn runtime_dir() -> PathBuf {
    let uid = nix_like_uid();
    std::env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(format!("/run/user/{uid}")))
        .join("s2t")
}

fn last_transcript_path() -> PathBuf {
    runtime_dir().join("last_transcript.txt")
}

fn nix_like_uid() -> u32 {
    std::env::var("UID")
        .ok()
        .and_then(|raw| raw.parse::<u32>().ok())
        .unwrap_or(1000)
}

fn load_last_transcript() -> Option<String> {
    std::fs::read_to_string(last_transcript_path())
        .ok()
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

fn persist_last_transcript(text: &str) {
    let path = last_transcript_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(&path, text) {
        error!(
            "Failed to persist last transcript to {}: {}",
            path.display(),
            e
        );
    }
}

async fn consume_transcription_updates(
    mut updates_rx: mpsc::UnboundedReceiver<TranscriptionEvent>,
    x11: Arc<X11Context>,
) {
    let mut last_partial = String::new();
    while let Some(event) = updates_rx.recv().await {
        match event {
            TranscriptionEvent::Partial(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() || trimmed == last_partial {
                    continue;
                }
                last_partial = trimmed.to_string();
                debug!("Partial transcription update: {}", trimmed);
                x11.set_last_text(last_partial.clone()).await;
            }
            TranscriptionEvent::Final(text) => {
                let trimmed = text.trim();
                if trimmed.is_empty() {
                    continue;
                }
                last_partial = trimmed.to_string();
                info!("Final transcription update: {}", trimmed);
                x11.set_last_text(last_partial.clone()).await;
            }
        }
    }
}

async fn run_file_e2e(provider: Arc<dyn TranscribeProvider>, audio_file: String) -> Result<()> {
    let (audio_tx, audio_rx) = mpsc::channel::<Vec<u8>>(128);
    let (updates_tx, mut updates_rx) = mpsc::unbounded_channel::<TranscriptionEvent>();
    let is_streaming = Arc::new(AtomicBool::new(true));
    let sample_rate = if provider.requires_audio_input() {
        let w = hound::WavReader::open(&audio_file)?;
        w.spec().sample_rate.max(1)
    } else {
        16_000u32
    };

    info!(
        "E2E mode enabled: audio_file='{}', provider={:?}",
        audio_file,
        provider.kind()
    );
    info!("Hotkey pressed. Starting stream...");
    let start_time = std::time::Instant::now();

    let provider_clone = provider.clone();
    let is_streaming_clone = is_streaming.clone();
    let transcribe_task = tokio::spawn(async move {
        provider_clone
            .stream_audio(audio_rx, sample_rate, is_streaming_clone, updates_tx)
            .await
    });

    if provider.requires_audio_input() {
        let mut wav = hound::WavReader::open(&audio_file)?;
        let spec = wav.spec();
        let in_rate = spec.sample_rate.max(1);
        let channels = spec.channels.max(1) as usize;
        let mut pcm = Vec::<u8>::new();
        let mut frame = Vec::<i16>::with_capacity(channels);
        for sample in wav.samples::<i16>() {
            frame.push(sample.unwrap_or(0));
            if frame.len() == channels {
                let mono = if channels == 1 {
                    frame[0]
                } else {
                    let sum: i32 = frame.iter().map(|v| *v as i32).sum();
                    (sum / channels as i32) as i16
                };
                pcm.extend_from_slice(&mono.to_le_bytes());
                frame.clear();
            }
        }
        let bytes_per_ms = ((in_rate as usize).saturating_mul(2) / 1000).max(1);
        let mut off = 0usize;
        while off < pcm.len() && is_streaming.load(Ordering::SeqCst) {
            let end = (off + bytes_per_ms.saturating_mul(20)).min(pcm.len());
            if audio_tx.send(pcm[off..end].to_vec()).await.is_err() {
                break;
            }
            off = end;
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    } else {
        let mut ff = tokio::process::Command::new("ffmpeg");
        ff.args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-re",
            "-i",
            &audio_file,
            "-ac",
            "1",
            "-ar",
            "16000",
        ]);
        if let Ok(alsa_dev) = std::env::var("S2T_E2E_ALSA_PLAYBACK_DEVICE") {
            if !alsa_dev.trim().is_empty() {
                info!(
                    "E2E local-stream feed: playing WAV into ALSA device '{}'",
                    alsa_dev
                );
                ff.args(["-f", "alsa", &alsa_dev]);
            }
        } else {
            let pulse_sink = std::env::var("S2T_E2E_PULSE_SINK")
                .unwrap_or_else(|_| "alsa_output.platform-snd_aloop.0.analog-stereo".to_string());
            info!(
                "E2E local-stream feed: playing WAV into pulse sink '{}'",
                pulse_sink
            );
            ff.args(["-f", "pulse", &pulse_sink]);
        }
        let status = ff.status().await?;
        if !status.success() {
            return Err(anyhow::anyhow!(
                "ffmpeg feed failed in E2E mode with status {}",
                status
            ));
        }
    }

    info!("Hotkey released. Stopping stream...");
    is_streaming.store(false, Ordering::SeqCst);
    drop(audio_tx);

    while let Ok(event) = updates_rx.try_recv() {
        match event {
            TranscriptionEvent::Partial(text) => info!("E2E partial: {}", text),
            TranscriptionEvent::Final(text) => info!("E2E final-event: {}", text),
        }
    }

    match tokio::time::timeout(Duration::from_secs(30), transcribe_task).await {
        Ok(joined) => match joined {
            Ok(Ok(text)) => {
                info!(
                    "Transcription received in {:?}: {}",
                    start_time.elapsed(),
                    text
                );
            }
            Ok(Err(e)) => {
                error!(
                    "Provider streaming error after {:?}: {:#}",
                    start_time.elapsed(),
                    e
                );
            }
            Err(e) => error!("E2E join error after {:?}: {}", start_time.elapsed(), e),
        },
        Err(_) => error!("E2E timeout waiting for transcription result"),
    }

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut logger_builder =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    logger_builder.format(|buf, record| {
        let ts = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z");
        writeln!(
            buf,
            "[{} {:<5} {}] {}",
            ts,
            record.level(),
            record.target(),
            record.args()
        )
    });
    logger_builder.init();

    info!("Starting S2T Rust Core (HTTP/3 Streaming)...");

    let runtime_cfg = RuntimeConfig::from_env()?;
    let provider = build_provider(&runtime_cfg)?;
    let provider_requires_audio = provider.requires_audio_input();
    info!("Using transcribe provider: {:?}", provider.kind());

    if let Ok(audio_file) = std::env::var("S2T_E2E_AUDIO_FILE") {
        if !audio_file.trim().is_empty() {
            return run_file_e2e(provider, audio_file).await;
        }
    }

    let (hotkey_tx, mut hotkey_rx) = mpsc::channel(10);

    let hotkey_tx_monitor = hotkey_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = modules::monitor::run(hotkey_tx_monitor).await {
            error!("Monitor error: {}", e);
        }
    });

    let mut recorder = AudioRecorder::new();
    if provider_requires_audio {
        recorder.prewarm();
    }
    let x11 = Arc::new(X11Context::new(hotkey_tx.clone())?);
    if let Some(text) = load_last_transcript() {
        x11.set_last_text(text).await;
    }

    let is_streaming = Arc::new(AtomicBool::new(false));
    let session_counter = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let last_pasted_session = Arc::new(std::sync::atomic::AtomicU64::new(0));
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
                let session_id = session_counter.fetch_add(1, Ordering::SeqCst) + 1;
                x11.capture_target_window().await;
                let start_time = std::time::Instant::now();
                let (audio_tx, audio_rx) = mpsc::channel::<Vec<u8>>(100);
                is_streaming.store(true, Ordering::SeqCst);

                let provider_clone = provider.clone();
                let x11_clone = x11.clone();
                let x11_updates = x11.clone();
                let is_streaming_clone = is_streaming.clone();
                let session_counter_updates = session_counter.clone();
                let session_counter_provider = session_counter.clone();
                let last_pasted_clone = last_pasted_session.clone();
                let (updates_tx, updates_rx) = mpsc::unbounded_channel::<TranscriptionEvent>();
                let requires_audio = provider_clone.requires_audio_input();
                let sample_rate = if requires_audio {
                    current_audio_tx = Some(audio_tx.clone());
                    match recorder.start(audio_tx) {
                        Ok(sr) => sr,
                        Err(e) => {
                            error!("Failed to start recorder: {}", e);
                            is_streaming.store(false, Ordering::SeqCst);
                            continue;
                        }
                    }
                } else {
                    current_audio_tx = None;
                    16_000
                };

                tokio::spawn(async move {
                    let mut updates_rx = updates_rx;
                    let mut last_partial = String::new();
                    while let Some(event) = updates_rx.recv().await {
                        if session_counter_updates.load(Ordering::SeqCst) != session_id {
                            break;
                        }
                        match event {
                            TranscriptionEvent::Partial(text) => {
                                let trimmed = text.trim();
                                if trimmed.is_empty() || trimmed == last_partial {
                                    continue;
                                }
                                last_partial = trimmed.to_string();
                                debug!("Partial transcription update: {}", trimmed);
                                x11_updates.set_last_text(last_partial.clone()).await;
                            }
                            TranscriptionEvent::Final(text) => {
                                let trimmed = text.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }
                                last_partial = trimmed.to_string();
                                info!("Final transcription update: {}", trimmed);
                                x11_updates.set_last_text(last_partial.clone()).await;
                            }
                        }
                    }
                });

                tokio::spawn(async move {
                    match provider_clone
                        .stream_audio(
                            audio_rx,
                            sample_rate,
                            is_streaming_clone.clone(),
                            updates_tx,
                        )
                        .await
                    {
                        Ok(text) => {
                            let elapsed = start_time.elapsed();
                            let cur = session_counter_provider.load(Ordering::SeqCst);
                            let last_pasted = last_pasted_clone.load(Ordering::SeqCst);
                            // Drop only if more than 2 sessions behind (truly stale)
                            // or a newer session already pasted (out-of-order guard).
                            if cur > session_id + 2 {
                                info!(
                                    "Dropping stale transcription session={} cur={}",
                                    session_id, cur
                                );
                            } else if last_pasted >= session_id && cur != session_id {
                                info!(
                                    "Skipping session={}: newer session already pasted",
                                    session_id
                                );
                            } else if !text.is_empty() {
                                info!("Transcription received in {:?}: {}", elapsed, text);
                                persist_last_transcript(&text);
                                x11_clone.set_last_text(text.clone()).await;
                                let paste_text = text.clone();
                                tokio::spawn(async move {
                                    let mut pasted = false;
                                    for attempt in 1..=3 {
                                        if let Err(e) =
                                            x11_clone.paste_secondary_fast(paste_text.clone()).await
                                        {
                                            error!(
                                                "Failed to auto-paste text (attempt {}): {}",
                                                attempt, e
                                            );
                                        } else {
                                            pasted = true;
                                            last_pasted_clone
                                                .fetch_max(session_id, Ordering::SeqCst);
                                            if attempt > 1 {
                                                info!("Auto-paste completed successfully on retry {}.", attempt);
                                            } else {
                                                info!("Auto-paste completed successfully.");
                                            }
                                            break;
                                        }
                                        tokio::time::sleep(Duration::from_millis(220)).await;
                                    }
                                    if !pasted {
                                        error!("Auto-paste failed after retries.");
                                    }
                                });
                            } else {
                                info!("Empty transcription received in {:?}.", elapsed);
                            }
                        }
                        Err(e) => {
                            error!(
                                "Provider streaming error after {:?}: {:#}",
                                start_time.elapsed(),
                                e
                            );
                            // Persist whatever partial we got so Alt+V can still paste it
                            // (secondary buffer already has the last partial via set_last_text)
                        }
                    }
                    is_streaming_clone.store(false, Ordering::SeqCst);
                });
            }
            HotkeyEvent::Released => {
                if !is_streaming.load(Ordering::SeqCst) {
                    continue;
                }
                info!("Hotkey released. Stopping stream...");
                // Important for true local streaming mode (whisper-stream):
                // provider loop exits when is_streaming becomes false.
                is_streaming.store(false, Ordering::SeqCst);
                if provider_requires_audio {
                    let _ = recorder.stop();
                }
                current_audio_tx.take();
                // Re-prewarm in background so the device is open before the next press,
                // eliminating the ~200 ms ALSA init delay that swallows the first syllable.
                if provider_requires_audio {
                    recorder.prewarm();
                }
            }
            HotkeyEvent::ManualPaste => {
                info!("Manual paste requested (Alt+V)...");
                x11.trigger_manual_paste().await;
            }
        }
    }

    Ok(())
}
