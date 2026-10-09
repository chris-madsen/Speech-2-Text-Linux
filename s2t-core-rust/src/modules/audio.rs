use anyhow::{anyhow, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use log::{error, info, warn};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tokio::sync::mpsc;

pub struct AudioRecorder {
    stream: Option<cpal::Stream>,
    is_running: Arc<AtomicBool>,
    audio_tx: Option<Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>>>,
    // Prewarm: holds the shared tx slot so we can plug in a real sender on start()
    prewarm_tx_arc: Option<Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>>>,
    prewarm_sample_rate: Option<u32>,
}

impl AudioRecorder {
    pub fn new() -> Self {
        Self {
            stream: None,
            is_running: Arc::new(AtomicBool::new(false)),
            audio_tx: None,
            prewarm_tx_arc: None,
            prewarm_sample_rate: None,
        }
    }

    /// Open the audio device and start the stream now, but discard all data.
    /// This eliminates the ~150-200 ms ALSA device enumeration delay on the
    /// first real start() call.
    pub fn prewarm(&mut self) {
        if self.stream.is_some() {
            return; // already open
        }
        let host = cpal::default_host();
        let device = match select_input_device(&host) {
            Ok(d) => d,
            Err(e) => {
                warn!("prewarm: could not open input device: {}", e);
                return;
            }
        };
        let device_name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        let config = match device.default_input_config() {
            Ok(c) => c,
            Err(e) => {
                warn!(
                    "prewarm: could not query input config for {}: {}",
                    device_name, e
                );
                return;
            }
        };
        let sample_rate = config.sample_rate().0;
        let channels = config.channels();
        let sample_format = config.sample_format();

        // Shared tx slot — starts empty so callback drops all data.
        let tx_arc: Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>> = Arc::new(Mutex::new(None));
        let is_running = self.is_running.clone();
        let stream_config: StreamConfig = config.config();

        let stream = match sample_format {
            SampleFormat::I8 => build_input_stream::<i8, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| (sample as i16) << 8,
            ),
            SampleFormat::I16 => build_input_stream::<i16, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| sample,
            ),
            SampleFormat::I32 => build_input_stream::<i32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| (sample >> 16) as i16,
            ),
            SampleFormat::I64 => build_input_stream::<i64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| (sample >> 48) as i16,
            ),
            SampleFormat::U8 => build_input_stream::<u8, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| ((sample as i16) - 128) << 8,
            ),
            SampleFormat::U16 => build_input_stream::<u16, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| ((sample as i32) - 32_768) as i16,
            ),
            SampleFormat::U32 => build_input_stream::<u32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| (((sample as i64) - 2_147_483_648_i64) >> 16) as i16,
            ),
            SampleFormat::U64 => build_input_stream::<u64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| (((sample as i128) - 9_223_372_036_854_775_808_i128) >> 48) as i16,
            ),
            SampleFormat::F32 => build_input_stream::<f32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                |sample| float_to_i16(sample as f64),
            ),
            SampleFormat::F64 => build_input_stream::<f64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc.clone(),
                float_to_i16,
            ),
            other => {
                warn!(
                    "prewarm: unsupported sample format {:?} for device {}",
                    other, device_name
                );
                return;
            }
        };

        match stream {
            Ok(s) => {
                if let Err(e) = s.play() {
                    warn!("prewarm: stream.play() failed: {}", e);
                    return;
                }
                info!(
                    "Prewarm: audio device '{}' opened ({} Hz, {} channels, {:?}). Ready.",
                    device_name, sample_rate, channels, sample_format
                );
                self.stream = Some(s);
                self.prewarm_tx_arc = Some(tx_arc);
                self.prewarm_sample_rate = Some(sample_rate);
            }
            Err(e) => warn!("prewarm: failed to build input stream: {}", e),
        }
    }

    pub fn start(&mut self, audio_tx: mpsc::Sender<Vec<u8>>) -> Result<u32> {
        // Fast path: reuse pre-warmed stream — just plug in the real sender.
        if let (Some(tx_arc), Some(sample_rate)) =
            (self.prewarm_tx_arc.take(), self.prewarm_sample_rate.take())
        {
            if let Ok(mut guard) = tx_arc.lock() {
                *guard = Some(audio_tx);
            }
            self.is_running.store(true, Ordering::SeqCst);
            self.audio_tx = Some(tx_arc);
            info!(
                "Recording started (reused pre-warmed stream, {} Hz).",
                sample_rate
            );
            return Ok(sample_rate);
        }

        // Slow path: open device from scratch.
        let host = cpal::default_host();
        let device = select_input_device(&host)?;
        let device_name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        let config = device
            .default_input_config()
            .with_context(|| format!("failed to query default input config for {}", device_name))?;
        let sample_rate = config.sample_rate().0;
        let channels = config.channels();
        let sample_format = config.sample_format();

        info!(
            "Recording started on '{}' (native {} Hz, {} channels, format={:?})...",
            device_name, sample_rate, channels, sample_format
        );

        self.is_running.store(true, Ordering::SeqCst);
        let is_running = self.is_running.clone();

        let tx_arc = Arc::new(Mutex::new(Some(audio_tx)));
        self.audio_tx = Some(tx_arc.clone());

        let stream_config: StreamConfig = config.config();
        let stream = match sample_format {
            SampleFormat::I8 => build_input_stream::<i8, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| (sample as i16) << 8,
            )?,
            SampleFormat::I16 => build_input_stream::<i16, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| sample,
            )?,
            SampleFormat::I32 => build_input_stream::<i32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| (sample >> 16) as i16,
            )?,
            SampleFormat::I64 => build_input_stream::<i64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| (sample >> 48) as i16,
            )?,
            SampleFormat::U8 => build_input_stream::<u8, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| ((sample as i16) - 128) << 8,
            )?,
            SampleFormat::U16 => build_input_stream::<u16, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| ((sample as i32) - 32_768) as i16,
            )?,
            SampleFormat::U32 => build_input_stream::<u32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| (((sample as i64) - 2_147_483_648_i64) >> 16) as i16,
            )?,
            SampleFormat::U64 => build_input_stream::<u64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| (((sample as i128) - 9_223_372_036_854_775_808_i128) >> 48) as i16,
            )?,
            SampleFormat::F32 => build_input_stream::<f32, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                |sample| float_to_i16(sample as f64),
            )?,
            SampleFormat::F64 => build_input_stream::<f64, _>(
                &device,
                &stream_config,
                channels,
                is_running,
                tx_arc,
                float_to_i16,
            )?,
            other => {
                return Err(anyhow!(
                    "unsupported input sample format {:?} for device {}",
                    other,
                    device_name
                ));
            }
        };

        stream.play()?;
        self.stream = Some(stream);
        Ok(sample_rate)
    }

    pub fn stop(&mut self) -> Result<()> {
        self.is_running.store(false, Ordering::SeqCst);

        if let Some(tx_arc) = self.audio_tx.take() {
            if let Ok(mut guard) = tx_arc.lock() {
                *guard = None;
            }
        }

        // Drop the stream entirely so the device is released;
        // prewarm() will re-open it fresh on next start().
        if let Some(stream) = self.stream.take() {
            let _ = stream.pause();
            drop(stream);
        }
        self.prewarm_tx_arc = None;
        self.prewarm_sample_rate = None;
        info!("Recording stopped.");
        Ok(())
    }
}

fn select_input_device(host: &cpal::Host) -> Result<cpal::Device> {
    let explicit_target = env_string("S2T_AUDIO_TARGET");
    let exclude_tokens = env_audio_exclude_tokens();
    let devices: Vec<cpal::Device> = host
        .input_devices()
        .context("failed to enumerate input devices")?
        .collect();

    if let Some(target) = explicit_target.as_ref() {
        let target_lower = target.to_ascii_lowercase();
        if let Some(device) = devices.iter().find(|device| {
            device
                .name()
                .map(|name| name.to_ascii_lowercase().contains(&target_lower))
                .unwrap_or(false)
        }) {
            info!("Using explicitly requested input device: {}", target);
            return Ok(device.clone());
        }
        warn!(
            "S2T_AUDIO_TARGET='{}' did not match any CPAL input device; falling back",
            target
        );
    }

    if let Some(device) = host.default_input_device() {
        let name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        if !is_excluded_audio_device(&name, &exclude_tokens) {
            return Ok(device);
        }
        warn!(
            "Default input device '{}' looks excluded; searching alternatives",
            name
        );
    }

    if let Some(device) = devices.iter().find(|device| {
        device
            .name()
            .map(|name| !is_excluded_audio_device(&name, &exclude_tokens))
            .unwrap_or(false)
    }) {
        let name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        info!("Using non-excluded fallback input device: {}", name);
        return Ok(device.clone());
    }

    host.default_input_device()
        .or_else(|| devices.into_iter().next())
        .ok_or_else(|| anyhow!("No input device found"))
}

fn build_input_stream<T, F>(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: u16,
    is_running: Arc<AtomicBool>,
    tx_arc: Arc<Mutex<Option<mpsc::Sender<Vec<u8>>>>>,
    convert_sample: F,
) -> Result<cpal::Stream>
where
    T: cpal::SizedSample + Copy + Send + 'static,
    F: Fn(T) -> i16 + Copy + Send + 'static,
{
    let channel_count = channels.max(1) as usize;
    let stream = device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            if !is_running.load(Ordering::SeqCst) {
                return;
            }

            let mono_data: Vec<i16> = if channel_count == 1 {
                data.iter().copied().map(convert_sample).collect()
            } else {
                data.chunks(channel_count)
                    .map(|chunk| {
                        let sum: i32 = chunk
                            .iter()
                            .copied()
                            .map(convert_sample)
                            .map(i32::from)
                            .sum();
                        (sum / (chunk.len() as i32).max(1)) as i16
                    })
                    .collect()
            };

            let mut bytes = Vec::with_capacity(mono_data.len() * 2);
            for sample in mono_data {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            if let Ok(guard) = tx_arc.lock() {
                if let Some(tx) = &*guard {
                    let _ = tx.try_send(bytes);
                }
            }
        },
        |err| error!("Audio stream error: {}", err),
        None,
    )?;
    Ok(stream)
}

fn float_to_i16(sample: f64) -> i16 {
    let clamped = sample.clamp(-1.0, 1.0);
    (clamped * f64::from(i16::MAX)) as i16
}

fn env_string(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|raw| raw.trim().trim_matches('"').to_string())
        .filter(|raw| !raw.is_empty())
}

fn env_audio_exclude_tokens() -> Vec<String> {
    env_string("S2T_AUDIO_TARGET_EXCLUDE_RE")
        .map(|raw| {
            raw.split('|')
                .map(|token| token.trim().trim_matches('"').to_ascii_lowercase())
                .filter(|token| !token.is_empty())
                .collect()
        })
        .unwrap_or_else(|| vec!["snd_aloop".into(), "loopback".into(), "monitor".into()])
}

fn is_excluded_audio_device(name: &str, exclude_tokens: &[String]) -> bool {
    let value = name.to_ascii_lowercase();
    exclude_tokens.iter().any(|token| value.contains(token))
}
