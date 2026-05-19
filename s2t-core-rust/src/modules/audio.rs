use anyhow::Result;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use log::{error, info};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tokio::sync::mpsc;

pub struct AudioRecorder {
    stream: Option<cpal::Stream>,
    is_running: Arc<AtomicBool>,
    audio_tx: Option<Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>>>,
}

impl AudioRecorder {
    pub fn new() -> Self {
        Self {
            stream: None,
            is_running: Arc::new(AtomicBool::new(false)),
            audio_tx: None,
        }
    }

    pub fn start(&mut self, audio_tx: mpsc::Sender<Vec<u8>>) -> Result<u32> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| anyhow::anyhow!("No input device found"))?;

        let config = device.default_input_config()?;
        let sample_rate = config.sample_rate().0;
        let channels = config.channels();

        info!(
            "Recording started (native {} Hz, {} channels)...",
            sample_rate, channels
        );

        self.is_running.store(true, Ordering::SeqCst);
        let is_running = self.is_running.clone();

        let tx_arc = Arc::new(Mutex::new(Some(audio_tx)));
        self.audio_tx = Some(tx_arc.clone());

        let stream = device.build_input_stream(
            &config.into(),
            move |data: &[i16], _: &cpal::InputCallbackInfo| {
                if is_running.load(Ordering::SeqCst) {
                    let mono_data: Vec<i16> = if channels == 2 {
                        data.chunks(2)
                            .map(|chunk| {
                                let l = chunk[0] as i32;
                                let r = chunk.get(1).copied().unwrap_or(0) as i32;
                                ((l + r) / 2) as i16
                            })
                            .collect()
                    } else {
                        data.to_vec()
                    };

                    let bytes: Vec<u8> = mono_data
                        .iter()
                        .flat_map(|&s| s.to_le_bytes().to_vec())
                        .collect();

                    if let Ok(guard) = tx_arc.lock() {
                        if let Some(tx) = &*guard {
                            let _ = tx.try_send(bytes);
                        }
                    }
                }
            },
            |err| error!("Audio stream error: {}", err),
            None,
        )?;

        stream.play()?;
        self.stream = Some(stream);
        Ok(sample_rate)
    }

    pub fn stop(&mut self) -> Result<()> {
        self.is_running.store(false, Ordering::SeqCst);

        // Explicitly drop the sender to close the channel immediately
        if let Some(tx_arc) = self.audio_tx.take() {
            if let Ok(mut guard) = tx_arc.lock() {
                *guard = None;
            }
        }

        if let Some(stream) = self.stream.take() {
            let _ = stream.pause();
            drop(stream);
        }
        info!("Recording stopped.");
        Ok(())
    }
}
