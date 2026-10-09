use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use aws_sdk_transcribestreaming::primitives::event_stream::EventStreamSender;
use aws_sdk_transcribestreaming::types::error::AudioStreamError;
use aws_sdk_transcribestreaming::types::{
    AudioEvent as AwsAudioEvent, AudioStream as AwsAudioStream, LanguageCode, MediaEncoding,
    TranscriptResultStream,
};
use aws_smithy_types::Blob;
use log::{debug, error, info, warn};
use serde_json::Value;
use std::env;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};
use tokio_stream::wrappers::ReceiverStream;
use tonic::{transport::Channel, Request};

pub mod google {
    pub mod cloud {
        pub mod speech {
            pub mod v2 {
                tonic::include_proto!("google.cloud.speech.v2");
            }
        }
    }
    pub mod rpc {
        tonic::include_proto!("google.rpc");
    }
    pub mod longrunning {
        tonic::include_proto!("google.longrunning");
    }
}

use google::cloud::speech::v2::{
    speech_client::SpeechClient, streaming_recognize_request::StreamingRequest,
    ExplicitDecodingConfig, RecognitionConfig, RecognitionFeatures, StreamingRecognitionConfig,
    StreamingRecognitionFeatures, StreamingRecognizeRequest,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderKind {
    Google,
    Local,
    Aws,
}

impl ProviderKind {
    pub fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "google" => Ok(Self::Google),
            "google-v2" => Ok(Self::Google),
            "local" => Ok(Self::Local),
            "aws" => Ok(Self::Aws),
            other => Err(anyhow!(
                "Unsupported S2T_ASR_PROVIDER='{other}' (expected google|local|aws)"
            )),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptionEvent {
    Partial(String),
    Final(String),
}

#[async_trait]
pub trait TranscribeProvider: Send + Sync {
    fn kind(&self) -> ProviderKind;
    fn requires_audio_input(&self) -> bool {
        true
    }

    async fn stream_audio(
        &self,
        audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
        updates_tx: mpsc::UnboundedSender<TranscriptionEvent>,
    ) -> Result<String>;
}

#[derive(Debug, Clone)]
pub struct GoogleConfig {
    pub project_id: String,
    pub location: String,
    pub recognizer_id: String,
    pub language_code: String,
    pub model: String,
    pub envoy_endpoint: String,
}

#[derive(Debug, Clone)]
pub struct LocalConfig {
    pub whisper_server_url: String,
    pub request_language: Option<String>,
    pub streaming_enabled: bool,
    pub stream_bin: String,
    pub model_path: String,
    pub threads: u32,
    pub stream_step_ms: u64,
    pub stream_length_ms: u64,
    pub stream_keep_ms: u64,
    pub stream_flush_after_release_ms: u64,
    pub stream_capture_id: Option<i32>,
    pub stream_keep_context: bool,
}

#[derive(Debug, Clone)]
pub struct AwsConfig {
    pub language_code: String,
    pub identify_language: bool,
    pub identify_mode: AwsIdentifyMode,
    pub language_options: Vec<String>,
    pub preferred_language: Option<String>,
    pub media_encoding: AwsMediaEncoding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwsIdentifyMode {
    Single,
    Multiple,
}

impl AwsIdentifyMode {
    fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "single" => Ok(Self::Single),
            "multiple" | "multi" => Ok(Self::Multiple),
            other => Err(anyhow!(
                "Unsupported S2T_AWS_IDENTIFY_MODE='{other}' (expected single|multiple)"
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwsMediaEncoding {
    Pcm,
    OggOpus,
}

impl AwsMediaEncoding {
    fn parse(raw: &str) -> Result<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "pcm" => Ok(Self::Pcm),
            "ogg-opus" | "ogg_opus" | "opus" => Ok(Self::OggOpus),
            other => Err(anyhow!(
                "Unsupported S2T_AWS_MEDIA_ENCODING='{other}' (expected pcm|ogg-opus)"
            )),
        }
    }
}

#[derive(Debug, Clone)]
pub struct RuntimeConfig {
    pub provider: ProviderKind,
    pub google: GoogleConfig,
    pub local: LocalConfig,
    pub aws: AwsConfig,
}

impl RuntimeConfig {
    pub fn from_env() -> Result<Self> {
        let provider_raw = env_var("S2T_ASR_PROVIDER").unwrap_or_else(|| "google".to_string());
        let provider = ProviderKind::parse(&provider_raw)?;

        let google_project_default = "poetic-emblem-494722-v2".to_string();
        let google_project = match env_var("S2T_GCP_PROJECT")
            .or_else(|| env_var("GOOGLE_CLOUD_PROJECT"))
        {
            Some(v) => v,
            None => {
                if provider == ProviderKind::Google {
                    warn!(
                        "S2T_GCP_PROJECT/GOOGLE_CLOUD_PROJECT are not set, using backward-compatible default '{}'.",
                        google_project_default
                    );
                }
                google_project_default
            }
        };

        let google_language =
            env_var("S2T_GOOGLE_LANGUAGE_CODE").unwrap_or_else(|| "ru-RU".to_string());
        let google = GoogleConfig {
            project_id: google_project,
            location: env_var("S2T_GOOGLE_V2_LOCATION")
                .unwrap_or_else(|| "europe-west4".to_string()),
            recognizer_id: env_var("S2T_GOOGLE_V2_RECOGNIZER").unwrap_or_else(|| "_".to_string()),
            language_code: google_language.clone(),
            model: env_var("S2T_GOOGLE_V2_MODEL").unwrap_or_else(|| "chirp_2".to_string()),
            envoy_endpoint: env_var("S2T_GOOGLE_ENVOY_ENDPOINT")
                .unwrap_or_else(|| "http://127.0.0.1:50051".to_string()),
        };

        let local_streaming_requested = env_var("S2T_LOCAL_STREAMING")
            .map(|v| parse_bool(&v, true))
            .unwrap_or(true);

        let local = LocalConfig {
            whisper_server_url: env_var("S2T_WHISPER_SERVER_URL")
                .unwrap_or_else(|| "http://127.0.0.1:9788/inference".to_string()),
            request_language: env_var("S2T_LOCAL_REQUEST_LANGUAGE")
                .or_else(|| env_var("S2T_LANG"))
                .map(|v| normalize_whisper_lang(&v))
                .filter(|v| !v.is_empty()),
            streaming_enabled: local_streaming_requested,
            stream_bin: env_var("S2T_LOCAL_STREAM_BIN")
                .unwrap_or_else(|| "/etc/s2t/result/bin/whisper-stream".to_string()),
            model_path: env_var("S2T_MODEL_PATH").unwrap_or_else(|| {
                format!(
                    "{}/.local/share/s2t/ggml-large-v3-turbo.bin",
                    env::var("HOME").unwrap_or_else(|_| "/home/ilja".to_string())
                )
            }),
            threads: env_var("S2T_THREADS")
                .and_then(|v| v.parse::<u32>().ok())
                .filter(|v| *v > 0)
                .unwrap_or(5),
            stream_step_ms: env_var("S2T_LOCAL_STREAM_STEP_MS")
                .and_then(|v| v.parse::<u64>().ok())
                .map(|v| v.clamp(300, 3000))
                .unwrap_or(600),
            stream_length_ms: env_var("S2T_LOCAL_STREAM_LENGTH_MS")
                .and_then(|v| v.parse::<u64>().ok())
                .map(|v| v.clamp(1000, 12000))
                .unwrap_or(2400),
            stream_keep_ms: env_var("S2T_LOCAL_STREAM_KEEP_MS")
                .and_then(|v| v.parse::<u64>().ok())
                .map(|v| v.clamp(0, 1000))
                .unwrap_or(120),
            stream_flush_after_release_ms: env_var("S2T_LOCAL_STREAM_FLUSH_MS")
                .and_then(|v| v.parse::<u64>().ok())
                .map(|v| v.clamp(500, 6000))
                .unwrap_or(700),
            stream_capture_id: env_var("S2T_LOCAL_STREAM_CAPTURE_ID")
                .and_then(|v| v.parse::<i32>().ok())
                .filter(|v| *v >= 0),
            stream_keep_context: env_var("S2T_LOCAL_STREAM_KEEP_CONTEXT")
                .map(|v| parse_bool(&v, true))
                .unwrap_or(true),
        };

        let aws_language_options = env_var("S2T_AWS_LANGUAGE_OPTIONS")
            .unwrap_or_else(|| "ru-RU,en-US".to_string())
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
            .collect::<Vec<_>>();

        let aws = AwsConfig {
            language_code: env_var("S2T_AWS_LANGUAGE_CODE")
                .or_else(|| env_var("S2T_GOOGLE_LANGUAGE_CODE"))
                .unwrap_or_else(|| "ru-RU".to_string()),
            identify_language: env_var("S2T_AWS_IDENTIFY_LANGUAGE")
                .map(|v| parse_bool(&v, true))
                .unwrap_or(true),
            identify_mode: AwsIdentifyMode::parse(
                &env_var("S2T_AWS_IDENTIFY_MODE").unwrap_or_else(|| "multiple".to_string()),
            )?,
            language_options: aws_language_options,
            preferred_language: env_var("S2T_AWS_PREFERRED_LANGUAGE")
                .or_else(|| env_var("S2T_AWS_LANGUAGE_CODE"))
                .or_else(|| Some("ru-RU".to_string())),
            media_encoding: AwsMediaEncoding::parse(
                &env_var("S2T_AWS_MEDIA_ENCODING").unwrap_or_else(|| "pcm".to_string()),
            )?,
        };

        if aws.identify_language && aws.language_options.is_empty() {
            return Err(anyhow!(
                "S2T_AWS_IDENTIFY_LANGUAGE is enabled but S2T_AWS_LANGUAGE_OPTIONS is empty"
            ));
        }

        Ok(Self {
            provider,
            google,
            local,
            aws,
        })
    }
}

fn parse_bool(raw: &str, default: bool) -> bool {
    match raw.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => true,
        "0" | "false" | "no" | "off" => false,
        _ => default,
    }
}

fn env_var(name: &str) -> Option<String> {
    let value = env::var(name).ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn normalize_whisper_lang(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let lowered = trimmed.to_ascii_lowercase();
    if lowered == "auto" {
        return "auto".to_string();
    }
    let primary = lowered.split(['-', '_']).next().unwrap_or("ru");
    match primary {
        "ru" => "ru".to_string(),
        "en" => "en".to_string(),
        "uk" => "uk".to_string(),
        "de" => "de".to_string(),
        "fr" => "fr".to_string(),
        "es" => "es".to_string(),
        "it" => "it".to_string(),
        "pt" => "pt".to_string(),
        other => other.to_string(),
    }
}

fn join_transcript_parts(prefix: &str, suffix: &str) -> String {
    let prefix = prefix.trim();
    let suffix = suffix.trim();
    match (prefix.is_empty(), suffix.is_empty()) {
        (true, true) => String::new(),
        (false, true) => prefix.to_string(),
        (true, false) => suffix.to_string(),
        (false, false) => format!("{prefix} {suffix}"),
    }
}

fn send_partial_update(
    updates_tx: &mpsc::UnboundedSender<TranscriptionEvent>,
    last_sent_partial: &mut String,
    text: impl Into<String>,
) {
    let text = text.into();
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed == last_sent_partial {
        return;
    }
    let normalized = trimmed.to_string();
    *last_sent_partial = normalized.clone();
    let _ = updates_tx.send(TranscriptionEvent::Partial(normalized));
}

fn send_final_update(
    updates_tx: &mpsc::UnboundedSender<TranscriptionEvent>,
    last_sent_partial: &mut String,
    text: impl Into<String>,
) {
    let text = text.into();
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    let normalized = trimmed.to_string();
    *last_sent_partial = normalized.clone();
    let _ = updates_tx.send(TranscriptionEvent::Final(normalized));
}

pub fn build_provider(config: &RuntimeConfig) -> Result<Arc<dyn TranscribeProvider>> {
    let provider: Arc<dyn TranscribeProvider> = match config.provider {
        ProviderKind::Google => Arc::new(GoogleProvider::new(config.google.clone())),
        ProviderKind::Local => Arc::new(LocalProvider::new(config.local.clone())),
        ProviderKind::Aws => Arc::new(AwsProvider::new(config.aws.clone())),
    };
    Ok(provider)
}

pub struct GoogleProvider {
    cfg: GoogleConfig,
}

impl GoogleProvider {
    pub fn new(cfg: GoogleConfig) -> Self {
        Self { cfg }
    }

    fn get_access_token(&self) -> Result<String> {
        let output = std::process::Command::new("gcloud")
            .args(["auth", "print-access-token"])
            .output()
            .context("Failed to execute gcloud auth")?;

        if !output.status.success() {
            return Err(anyhow!(
                "gcloud auth failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }

        Ok(String::from_utf8(output.stdout)?.trim().to_string())
    }
}

#[async_trait]
impl TranscribeProvider for GoogleProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Google
    }

    async fn stream_audio(
        &self,
        mut audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
        updates_tx: mpsc::UnboundedSender<TranscriptionEvent>,
    ) -> Result<String> {
        let token = self.get_access_token()?;
        info!(
            "Starting gRPC streaming to Google Cloud via Envoy ({} Hz, Opus)...",
            sample_rate
        );

        let channel = Channel::from_shared(self.cfg.envoy_endpoint.clone())?
            .connect()
            .await?;

        let project_id = self.cfg.project_id.clone();
        let mut client =
            SpeechClient::with_interceptor(channel, move |mut req: tonic::Request<()>| {
                req.metadata_mut().insert(
                    "authorization",
                    format!("Bearer {}", token).parse().unwrap(),
                );
                req.metadata_mut()
                    .insert("x-goog-user-project", project_id.parse().unwrap());
                Ok(req)
            });

        let recognizer = format!(
            "projects/{}/locations/{}/recognizers/{}",
            self.cfg.project_id, self.cfg.location, self.cfg.recognizer_id
        );

        let mut ffmpeg = tokio::process::Command::new("ffmpeg")
            .args([
                "-f",
                "s16le",
                "-ar",
                &sample_rate.to_string(),
                "-ac",
                "1",
                "-i",
                "pipe:0",
                "-c:a",
                "libopus",
                "-b:a",
                "24k",
                "-f",
                "ogg",
                "pipe:1",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("Failed to spawn ffmpeg")?;

        let mut stdin = ffmpeg.stdin.take().unwrap();
        let mut stdout = ffmpeg.stdout.take().unwrap();

        tokio::spawn(async move {
            // Pre-fill: send 600 ms of silence so the Opus encoder and gRPC
            // stream are fully initialised before real speech arrives.
            // This prevents the first word from being clipped due to
            // TLS/HTTP-2 + gRPC setup latency (~300-500 ms).
            let silence_samples = (sample_rate as usize * 600 / 1000) * 2; // 16-bit mono
            let silence = vec![0u8; silence_samples];
            if stdin.write_all(&silence).await.is_err() {
                debug!("ffmpeg stdin silence pre-fill write error");
                drop(stdin);
                return;
            }
            debug!("google feeder: sent 600 ms silence pre-fill");
            while let Some(chunk) = audio_rx.recv().await {
                if stdin.write_all(&chunk).await.is_err() {
                    debug!("ffmpeg stdin write error, breaking");
                    break;
                }
                if !is_streaming.load(Ordering::SeqCst) {
                    debug!("is_streaming is false, breaking");
                    break;
                }
            }
            debug!("audio_rx closed or loop broken, dropping stdin");
            drop(stdin);
        });

        let language_code = self.cfg.language_code.clone();
        let model = self.cfg.model.clone();
        let outbound = async_stream::stream! {
            yield StreamingRecognizeRequest {
                recognizer: recognizer.clone(),
                streaming_request: Some(StreamingRequest::StreamingConfig(
                    StreamingRecognitionConfig {
                        config: Some(RecognitionConfig {
                            decoding_config: Some(google::cloud::speech::v2::recognition_config::DecodingConfig::ExplicitDecodingConfig(
                                ExplicitDecodingConfig {
                                    encoding: 6,
                                    sample_rate_hertz: sample_rate as i32,
                                    audio_channel_count: 1,
                                }
                            )),
                            language_codes: vec![language_code],
                            model,
                            features: Some(RecognitionFeatures {
                                enable_automatic_punctuation: true,
                                ..Default::default()
                            }),
                            ..Default::default()
                        }),
                        streaming_features: Some(StreamingRecognitionFeatures {
                            interim_results: true,
                            ..Default::default()
                        }),
                        ..Default::default()
                    }
                )),
            };

            let mut buffer = vec![0u8; 4096];
            loop {
                match stdout.read(&mut buffer).await {
                    Ok(0) => {
                        debug!("ffmpeg stdout EOF");
                        break;
                    }
                    Ok(n) => {
                        yield StreamingRecognizeRequest {
                            recognizer: recognizer.clone(),
                            streaming_request: Some(StreamingRequest::Audio(buffer[..n].to_vec())),
                        };
                    }
                    Err(e) => {
                        error!("ffmpeg stdout read error: {}", e);
                        break;
                    }
                }
            }
            debug!("outbound stream ended");
        };

        let response = client.streaming_recognize(Request::new(outbound)).await?;
        let mut inbound = response.into_inner();

        let mut final_transcript = String::new();
        let mut last_sent_partial = String::new();
        let start_wait = std::time::Instant::now();
        while let Some(resp) = inbound.message().await? {
            if let Some(results) = resp.results.first() {
                if let Some(alt) = results.alternatives.first() {
                    if results.is_final {
                        debug!(
                            "Final result received after {:?}: {}",
                            start_wait.elapsed(),
                            alt.transcript
                        );
                        final_transcript.push_str(&alt.transcript);
                        final_transcript.push(' ');
                        send_partial_update(
                            &updates_tx,
                            &mut last_sent_partial,
                            final_transcript.trim().to_string(),
                        );
                    } else {
                        debug!(
                            "Interim result after {:?}: {}",
                            start_wait.elapsed(),
                            alt.transcript
                        );
                        send_partial_update(
                            &updates_tx,
                            &mut last_sent_partial,
                            join_transcript_parts(&final_transcript, &alt.transcript),
                        );
                    }
                }
            }
        }
        info!(
            "Google Cloud stream closed after {:?}",
            start_wait.elapsed()
        );
        let final_text = final_transcript.trim().to_string();
        send_final_update(&updates_tx, &mut last_sent_partial, final_text.clone());
        Ok(final_text)
    }
}

pub struct LocalProvider {
    cfg: LocalConfig,
    http: reqwest::Client,
}

#[derive(Debug, Clone)]
struct LocalTranscription {
    text: String,
    detected_language: Option<String>,
}

impl LocalProvider {
    pub fn new(cfg: LocalConfig) -> Self {
        Self {
            cfg,
            http: reqwest::Client::new(),
        }
    }
    async fn transcribe_pcm_wav(&self, sample_rate: u32, pcm_bytes: Vec<u8>) -> Result<String> {
        self.transcribe_pcm_wav_with_lang(sample_rate, pcm_bytes, None)
            .await
    }

    async fn transcribe_pcm_wav_result_with_lang(
        &self,
        sample_rate: u32,
        pcm_bytes: Vec<u8>,
        lang_override: Option<&str>,
    ) -> Result<LocalTranscription> {
        if pcm_bytes.is_empty() {
            return Ok(LocalTranscription {
                text: String::new(),
                detected_language: None,
            });
        }
        let prep_started = Instant::now();
        let target_rate = 16_000u32;

        let in_samples = pcm_bytes.len() / 2;
        let normalized_i16 = Self::resample_mono_s16le(&pcm_bytes, sample_rate, target_rate);
        let out_samples = normalized_i16.len();

        let mut cursor = std::io::Cursor::new(Vec::new());
        {
            let spec = hound::WavSpec {
                channels: 1,
                sample_rate: target_rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            let mut writer =
                hound::WavWriter::new(&mut cursor, spec).context("failed to create WAV encoder")?;
            for s in normalized_i16 {
                writer
                    .write_sample(s)
                    .context("failed to write WAV sample")?;
            }
            writer.finalize().context("failed to finalize WAV")?;
        }

        let wav_bytes = cursor.into_inner();
        debug!(
            "local wav prep: in_rate={} -> out_rate={}, in_samples={}, out_samples={}, wav_bytes={}, prep_ms={}",
            sample_rate,
            target_rate,
            in_samples,
            out_samples,
            wav_bytes.len(),
            prep_started.elapsed().as_millis()
        );
        let part = reqwest::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;
        let mut form = reqwest::multipart::Form::new().part("file", part);
        let lang_to_use = Self::normalize_request_language_param(
            lang_override
                .map(|v| v.to_string())
                .or_else(|| self.cfg.request_language.clone())
                .as_deref(),
        );
        if let Some(lang) = &lang_to_use {
            form = form.text("language", lang.clone());
        }

        let request_started = Instant::now();
        let response = self
            .http
            .post(&self.cfg.whisper_server_url)
            .multipart(form)
            .send()
            .await
            .context("local whisper-server request failed")?;

        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        debug!(
            "local whisper request done: status={}, roundtrip_ms={}, body_len={}, lang_hint={:?}",
            status,
            request_started.elapsed().as_millis(),
            body.len(),
            lang_to_use
        );
        if !status.is_success() {
            return Err(anyhow!(
                "local whisper-server returned {}: {}",
                status,
                body
            ));
        }

        let parsed: Value =
            serde_json::from_str(&body).context("failed to parse whisper-server JSON response")?;
        let text = parsed
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let detected_language =
            Self::extract_response_language(&parsed).or_else(|| Self::infer_lang_from_text(&text));

        Ok(LocalTranscription {
            text,
            detected_language,
        })
    }

    async fn transcribe_pcm_wav_with_lang(
        &self,
        sample_rate: u32,
        pcm_bytes: Vec<u8>,
        lang_override: Option<&str>,
    ) -> Result<String> {
        self.transcribe_pcm_wav_result_with_lang(sample_rate, pcm_bytes, lang_override)
            .await
            .map(|result| result.text)
    }

    fn infer_lang_from_text(text: &str) -> Option<String> {
        let mut cyr = 0usize;
        let mut lat = 0usize;
        for ch in text.chars() {
            if ('\u{0400}'..='\u{04FF}').contains(&ch) {
                cyr += 1;
            } else if ch.is_ascii_alphabetic() {
                lat += 1;
            }
        }
        if cyr >= 3 && cyr >= lat {
            Some("ru".to_string())
        } else if lat >= 3 {
            Some("en".to_string())
        } else {
            None
        }
    }

    fn normalize_request_language_param(raw: Option<&str>) -> Option<String> {
        let raw = raw?;
        let normalized = normalize_whisper_lang(raw);
        if normalized.is_empty() || normalized.eq_ignore_ascii_case("auto") {
            None
        } else {
            Some(normalized)
        }
    }

    fn extract_response_language(parsed: &Value) -> Option<String> {
        let candidates = [
            parsed.get("language"),
            parsed.get("result").and_then(|v| v.get("language")),
            parsed
                .get("result")
                .and_then(|v| v.get("whisper"))
                .and_then(|v| v.get("language")),
            parsed.get("whisper").and_then(|v| v.get("language")),
        ];
        for candidate in candidates.into_iter().flatten() {
            if let Some(raw) = candidate.as_str() {
                let normalized = normalize_whisper_lang(raw);
                if !normalized.is_empty() && !normalized.eq_ignore_ascii_case("auto") {
                    return Some(normalized);
                }
            }
        }
        None
    }

    fn update_detected_lang(
        auto_mode: bool,
        detected_lang: &mut Option<String>,
        result: &LocalTranscription,
    ) {
        if !auto_mode || detected_lang.is_some() {
            return;
        }
        *detected_lang = result
            .detected_language
            .clone()
            .or_else(|| Self::infer_lang_from_text(&result.text));
        if let Some(lang) = detected_lang.as_deref() {
            debug!("local auto-lang locked to '{}'", lang);
        }
    }

    fn resample_mono_s16le(input_pcm: &[u8], in_rate: u32, out_rate: u32) -> Vec<i16> {
        if input_pcm.is_empty() {
            return Vec::new();
        }
        let in_rate = in_rate.max(1);
        let out_rate = out_rate.max(1);

        let mut in_samples = Vec::with_capacity(input_pcm.len() / 2);
        for sample in input_pcm.chunks_exact(2) {
            in_samples.push(i16::from_le_bytes([sample[0], sample[1]]));
        }
        if in_samples.is_empty() {
            return Vec::new();
        }
        if in_rate == out_rate {
            return in_samples;
        }

        let out_len =
            ((in_samples.len() as u64).saturating_mul(out_rate as u64) / in_rate as u64) as usize;
        if out_len == 0 {
            return vec![in_samples[0]];
        }

        let mut out = Vec::with_capacity(out_len);
        for j in 0..out_len {
            let src_idx = ((j as u64).saturating_mul(in_rate as u64) / out_rate as u64) as usize;
            let idx = src_idx.min(in_samples.len().saturating_sub(1));
            out.push(in_samples[idx]);
        }
        out
    }

    fn strip_ansi(input: &str) -> String {
        let mut out = String::with_capacity(input.len());
        let mut chars = input.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch == '\u{1b}' {
                if matches!(chars.peek(), Some('[')) {
                    let _ = chars.next();
                    while let Some(c) = chars.next() {
                        // CSI final byte range
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                continue;
            }
            out.push(ch);
        }
        out
    }

    fn extract_whisper_stream_text(raw: &str) -> String {
        let cleaned = Self::strip_ansi(raw);
        let mut best = String::new();
        let mut preferred = String::new();
        for line in cleaned.split(['\n', '\r']) {
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            let lower = t.to_ascii_lowercase();
            if t.starts_with("main:")
                || t.starts_with("init:")
                || t.starts_with("ALSA lib ")
                || t.contains("snd_pcm_")
                || t.contains("[error")
                || t.starts_with("whisper_")
                || t.starts_with("ggml_")
                || t.starts_with("load_backend:")
                || t.starts_with("system_info:")
                || t.starts_with('[')
                || t.contains("processing ")
                || t.contains("sample rate")
                || t.contains("CUDA")
                || t.contains("Device 0:")
                || t.contains("devices:")
                || t.contains("tensor cores")
                || t.contains("suboptimal performance")
                || t.contains("Consider compiling")
                || t.contains("CMAKE_CUDA_ARCHITECTURES")
                || t.contains("DGGML_CUDA_FORCE_MMQ")
                || lower.starts_with("the following devices")
                || lower.starts_with("consider compiling")
            {
                continue;
            }
            if t.chars().any(|c| ('\u{0400}'..='\u{04FF}').contains(&c)) {
                if t.chars().count() >= preferred.chars().count() {
                    preferred = t.to_string();
                }
            } else if t.chars().count() >= best.chars().count() {
                best = t.to_string();
            }
        }
        if !preferred.is_empty() {
            preferred
        } else {
            best
        }
    }

    async fn transcribe_true_stream(
        &self,
        is_streaming: Arc<AtomicBool>,
        updates_tx: &mpsc::UnboundedSender<TranscriptionEvent>,
    ) -> Result<String> {
        let stream_bin = PathBuf::from(&self.cfg.stream_bin);
        if !stream_bin.exists() {
            return Err(anyhow!(
                "local stream binary not found: {}",
                stream_bin.display()
            ));
        }
        let model_path = PathBuf::from(&self.cfg.model_path);
        if !model_path.exists() {
            return Err(anyhow!(
                "local model not found for stream mode: {}",
                model_path.display()
            ));
        }

        let lang = self
            .cfg
            .request_language
            .clone()
            .unwrap_or_else(|| "ru".to_string());

        let mut cmd = tokio::process::Command::new(&self.cfg.stream_bin);
        cmd.env("GGML_CUDA_FORCE_MMQ", "1");
        cmd.env("SDL_AUDIODRIVER", "pulseaudio");
        cmd.args([
            "-m",
            &self.cfg.model_path,
            "-l",
            &lang,
            "-t",
            &self.cfg.threads.to_string(),
            "--step",
            &self.cfg.stream_step_ms.to_string(),
            "--length",
            &self.cfg.stream_length_ms.to_string(),
            "--keep",
            &self.cfg.stream_keep_ms.to_string(),
            "-bs",
            "-1",
            "-nf",
            "-fa",
        ]);
        if let Some(cid) = self.cfg.stream_capture_id {
            cmd.args(["-c", &cid.to_string()]);
        }
        if self.cfg.stream_keep_context {
            cmd.arg("-kc");
        }
        let mut child = cmd
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("failed to start whisper-stream")?;

        let mut stdout = child
            .stdout
            .take()
            .context("no stdout from whisper-stream")?;
        let mut stderr = child
            .stderr
            .take()
            .context("no stderr from whisper-stream")?;

        let (chunk_tx, mut chunk_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let tx_out = chunk_tx.clone();
        let stdout_reader = tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match stdout.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        let _ = tx_out.send(String::from_utf8_lossy(&buf[..n]).to_string());
                    }
                    Err(_) => break,
                }
            }
        });
        let tx_err = chunk_tx.clone();
        let stderr_reader = tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match stderr.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        let _ = tx_err.send(String::from_utf8_lossy(&buf[..n]).to_string());
                    }
                    Err(_) => break,
                }
            }
        });
        drop(chunk_tx);

        let mut raw_output = String::new();
        let mut best_text = String::new();
        let mut best_score = 0usize;
        let mut last_sent_partial = String::new();

        while is_streaming.load(Ordering::SeqCst) {
            while let Ok(chunk) = chunk_rx.try_recv() {
                raw_output.push_str(&chunk);
                Self::update_best_text(&raw_output, &mut best_text, &mut best_score);
                if !best_text.trim().is_empty() {
                    send_partial_update(updates_tx, &mut last_sent_partial, best_text.clone());
                }
            }
            if let Some(_status) = child.try_wait()? {
                break;
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }

        let release_ts = Instant::now();
        if child.try_wait()?.is_none() {
            if let Some(pid) = child.id() {
                let _ = tokio::process::Command::new("kill")
                    .args(["-INT", &pid.to_string()])
                    .status()
                    .await;
            }
        }

        let flush_deadline = Instant::now()
            + Duration::from_millis(self.cfg.stream_flush_after_release_ms.clamp(100, 1500));
        while Instant::now() < flush_deadline {
            while let Ok(chunk) = chunk_rx.try_recv() {
                raw_output.push_str(&chunk);
                Self::update_best_text(&raw_output, &mut best_text, &mut best_score);
                if !best_text.trim().is_empty() {
                    send_partial_update(updates_tx, &mut last_sent_partial, best_text.clone());
                }
            }
            if child.try_wait()?.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        if child.try_wait()?.is_none() {
            let _ = child.start_kill();
            if timeout(Duration::from_millis(700), child.wait())
                .await
                .is_err()
            {
                let _ = child.kill().await;
                let _ = timeout(Duration::from_millis(300), child.wait()).await;
            }
        }

        let _ = timeout(Duration::from_millis(300), stdout_reader).await;
        let _ = timeout(Duration::from_millis(300), stderr_reader).await;
        while let Ok(chunk) = chunk_rx.try_recv() {
            raw_output.push_str(&chunk);
            Self::update_best_text(&raw_output, &mut best_text, &mut best_score);
            if !best_text.trim().is_empty() {
                send_partial_update(updates_tx, &mut last_sent_partial, best_text.clone());
            }
        }

        let text = if best_text.trim().is_empty() {
            Self::extract_whisper_stream_text(&raw_output)
        } else {
            best_text
        };
        info!(
            "local true-stream finalize: release_to_text={:?}, text_chars={}",
            release_ts.elapsed(),
            text.chars().count()
        );

        if text.trim().is_empty() {
            let err_tail = raw_output
                .lines()
                .rev()
                .take(12)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join(" | ");
            return Err(anyhow!(
                "whisper-stream returned empty transcript (tail: {})",
                err_tail
            ));
        }
        Ok(text)
    }

    fn adaptive_step_ms(total_audio_ms: u64, last_snapshot_ms: Option<u64>) -> u64 {
        let mut step = if total_audio_ms < 2_500 {
            650
        } else if total_audio_ms < 8_000 {
            900
        } else if total_audio_ms < 20_000 {
            1_200
        } else {
            1_800
        };

        if let Some(lat) = last_snapshot_ms {
            if lat > 1_800 {
                step = step.max((lat as f64 * 0.75) as u64);
            }
        }

        step.clamp(350, 2_000)
    }

    fn min_snapshot_start_ms(total_audio_ms: u64) -> u64 {
        if total_audio_ms < 4_000 {
            4_000
        } else if total_audio_ms < 10_000 {
            1_200
        } else if total_audio_ms < 15_000 {
            1_200
        } else if total_audio_ms < 18_000 {
            1_600
        } else {
            2_000
        }
    }

    fn release_wait_timeout_ms(inflight_audio_ms: u64) -> u64 {
        // Keep release latency low; prefer already-computed snapshot and avoid long stalls.
        (inflight_audio_ms / 2).clamp(450, 1000)
    }

    fn text_word_count(text: &str) -> usize {
        text.split_whitespace().count()
    }

    fn text_score(text: &str) -> usize {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return 0;
        }
        let words = Self::text_word_count(trimmed);
        trimmed.chars().count() + words * 12
    }

    fn looks_sentence_complete(text: &str) -> bool {
        let t = text.trim_end();
        if t.is_empty() {
            return false;
        }
        match t.chars().last() {
            Some('.') | Some('!') | Some('?') | Some('…') => true,
            Some('"') | Some('»') | Some('\'') => {
                let base = t.trim_end_matches(['"', '»', '\'']);
                matches!(
                    base.chars().last(),
                    Some('.') | Some('!') | Some('?') | Some('…')
                )
            }
            _ => false,
        }
    }

    fn update_best_text(raw: &str, best_text: &mut String, best_score: &mut usize) {
        let candidate = Self::extract_whisper_stream_text(raw);
        let score = Self::text_score(&candidate);
        if score > 0 && score >= *best_score {
            *best_score = score;
            *best_text = candidate;
        }
    }

    fn should_force_full_pass(total_audio_ms: u64, best_audio_ms: u64, text: &str) -> bool {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return true;
        }
        let words = Self::text_word_count(trimmed);
        let chars = trimmed.chars().count();
        let complete = Self::looks_sentence_complete(trimmed);
        let coverage = if total_audio_ms == 0 {
            0.0
        } else {
            best_audio_ms as f64 / total_audio_ms as f64
        };

        if best_audio_ms.saturating_add(250) >= total_audio_ms && (chars >= 4 || words >= 1) {
            return false;
        }
        if total_audio_ms <= 4_000 && coverage >= 0.65 && (chars >= 8 || words >= 2) {
            return false;
        }
        if total_audio_ms <= 8_000 && coverage >= 0.75 && (chars >= 14 || words >= 3) {
            return false;
        }
        if total_audio_ms <= 15_000 && coverage >= 0.80 && (chars >= 20 || words >= 4) {
            return false;
        }

        if best_audio_ms.saturating_add(500) < total_audio_ms {
            let tail_gap_ms = total_audio_ms.saturating_sub(best_audio_ms);
            // Avoid cutting off last words: if the tail gap is noticeable and sentence
            // does not look complete, prefer full pass.
            if tail_gap_ms > 260 && !complete {
                return true;
            }
            // For short utterances, accept stream result only when coverage is high enough.
            if !(coverage >= 0.85 && chars >= 35 && words >= 6) {
                return true;
            }
        }

        if total_audio_ms >= 6_000 && (words < 4 || chars < 20) {
            return true;
        }
        if total_audio_ms >= 12_000 && (words < 8 || chars < 45) {
            return true;
        }
        false
    }

    fn clone_for_task(&self) -> Self {
        Self {
            cfg: self.cfg.clone(),
            http: self.http.clone(),
        }
    }
}

#[async_trait]
impl TranscribeProvider for LocalProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Local
    }

    fn requires_audio_input(&self) -> bool {
        !self.cfg.streaming_enabled
    }

    async fn stream_audio(
        &self,
        mut audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
        updates_tx: mpsc::UnboundedSender<TranscriptionEvent>,
    ) -> Result<String> {
        if self.cfg.streaming_enabled {
            info!(
                "Starting local true-stream mode via whisper-stream (language={:?}, step_ms={}, length_ms={}, keep_ms={})...",
                self.cfg.request_language,
                self.cfg.stream_step_ms,
                self.cfg.stream_length_ms,
                self.cfg.stream_keep_ms
            );
            let text = self
                .transcribe_true_stream(is_streaming, &updates_tx)
                .await?;
            send_final_update(&updates_tx, &mut String::new(), text.clone());
            return Ok(text);
        }

        info!(
            "Starting local streaming over whisper-server snapshots ({} Hz, language={:?})...",
            sample_rate, self.cfg.request_language
        );

        let mut pcm_bytes = Vec::new();
        let bytes_per_ms = ((sample_rate as usize).saturating_mul(2) / 1000).max(1);
        let mut bytes_since_snapshot = 0usize;
        let mut snapshot_task: Option<tokio::task::JoinHandle<Result<LocalTranscription>>> = None;
        let mut snapshot_started_at: Option<Instant> = None;
        let mut last_snapshot_latency_ms: Option<u64> = None;
        let mut inflight_snapshot_audio_ms: Option<u64> = None;
        let mut best_stream_text = String::new();
        let mut best_stream_score = 0usize;
        let mut best_stream_audio_ms = 0u64;
        let mut last_sent_partial = String::new();
        let auto_mode = self
            .cfg
            .request_language
            .as_deref()
            .map(|v| v.eq_ignore_ascii_case("auto"))
            .unwrap_or(false);
        let mut detected_lang: Option<String> = None;

        while let Some(chunk) = audio_rx.recv().await {
            if chunk.is_empty() {
                continue;
            }
            bytes_since_snapshot = bytes_since_snapshot.saturating_add(chunk.len());
            pcm_bytes.extend_from_slice(&chunk);

            if let Some(handle) = snapshot_task.take() {
                if handle.is_finished() {
                    if let Some(started) = snapshot_started_at.take() {
                        last_snapshot_latency_ms = Some(started.elapsed().as_millis() as u64);
                    }
                    match handle.await {
                        Ok(Ok(result)) if !result.text.trim().is_empty() => {
                            Self::update_detected_lang(auto_mode, &mut detected_lang, &result);
                            let score = Self::text_score(&result.text);
                            let covered_ms = inflight_snapshot_audio_ms.unwrap_or(0);
                            if covered_ms >= best_stream_audio_ms || score >= best_stream_score {
                                best_stream_audio_ms = covered_ms;
                                best_stream_score = score;
                                best_stream_text = result.text;
                                send_partial_update(
                                    &updates_tx,
                                    &mut last_sent_partial,
                                    best_stream_text.clone(),
                                );
                            }
                        }
                        Ok(Ok(_)) => {}
                        Ok(Err(e)) => warn!("local snapshot streaming error: {:#}", e),
                        Err(e) => warn!("local snapshot task join error: {}", e),
                    }
                } else {
                    snapshot_task = Some(handle);
                }
            }

            let total_audio_ms = (pcm_bytes.len() / bytes_per_ms) as u64;
            let step_ms = Self::adaptive_step_ms(total_audio_ms, last_snapshot_latency_ms);
            let step_bytes = (step_ms as usize).saturating_mul(bytes_per_ms).max(3200);
            let min_start_ms = Self::min_snapshot_start_ms(total_audio_ms);
            let min_start_bytes = (min_start_ms as usize)
                .saturating_mul(bytes_per_ms)
                .max(3200);

            if bytes_since_snapshot >= step_bytes
                && pcm_bytes.len() >= min_start_bytes
                && snapshot_task.is_none()
            {
                bytes_since_snapshot = 0;
                let snapshot = pcm_bytes.clone();
                let provider = self.clone_for_task();
                let lang_hint = detected_lang.clone();
                snapshot_started_at = Some(Instant::now());
                inflight_snapshot_audio_ms = Some(total_audio_ms);
                debug!(
                    "local snapshot start: total_audio_ms={}, bytes={}",
                    total_audio_ms,
                    snapshot.len()
                );
                snapshot_task = Some(tokio::spawn(async move {
                    provider
                        .transcribe_pcm_wav_result_with_lang(
                            sample_rate,
                            snapshot,
                            lang_hint.as_deref(),
                        )
                        .await
                }));
            }

            if !is_streaming.load(Ordering::SeqCst) {
                break;
            }
        }

        if pcm_bytes.is_empty() {
            return Ok(String::new());
        }

        if let Some(handle) = snapshot_task.take() {
            if handle.is_finished() {
                if let Some(started) = snapshot_started_at.take() {
                    last_snapshot_latency_ms = Some(started.elapsed().as_millis() as u64);
                }
                match handle.await {
                    Ok(Ok(result)) if !result.text.trim().is_empty() => {
                        Self::update_detected_lang(auto_mode, &mut detected_lang, &result);
                        let score = Self::text_score(&result.text);
                        let covered_ms = inflight_snapshot_audio_ms.unwrap_or(0);
                        if covered_ms >= best_stream_audio_ms || score >= best_stream_score {
                            best_stream_audio_ms = covered_ms;
                            best_stream_score = score;
                            best_stream_text = result.text;
                        }
                    }
                    Ok(Ok(_)) => {}
                    Ok(Err(e)) => warn!("local snapshot final join error: {:#}", e),
                    Err(e) => warn!("local snapshot task join error: {}", e),
                }
            } else if best_stream_score > 0 {
                let final_audio_ms = (pcm_bytes.len() / bytes_per_ms) as u64;
                let inflight_audio_ms = inflight_snapshot_audio_ms.unwrap_or(final_audio_ms);
                let snapshot_covers_all_audio =
                    inflight_audio_ms.saturating_add(900) >= final_audio_ms;
                if snapshot_covers_all_audio {
                    let wait_ms = Self::release_wait_timeout_ms(inflight_audio_ms);
                    debug!(
                        "local: waiting in-flight full snapshot after release (wait_ms={}, inflight_audio_ms={}, final_audio_ms={})",
                        wait_ms, inflight_audio_ms, final_audio_ms
                    );
                    let mut handle = handle;
                    match timeout(Duration::from_millis(wait_ms), &mut handle).await {
                        Ok(joined) => {
                            if let Some(started) = snapshot_started_at.take() {
                                last_snapshot_latency_ms =
                                    Some(started.elapsed().as_millis() as u64);
                            }
                            match joined {
                                Ok(Ok(result)) if !result.text.trim().is_empty() => {
                                    Self::update_detected_lang(
                                        auto_mode,
                                        &mut detected_lang,
                                        &result,
                                    );
                                    let score = Self::text_score(&result.text);
                                    let covered_ms = inflight_snapshot_audio_ms.unwrap_or(0);
                                    if covered_ms >= best_stream_audio_ms
                                        || score >= best_stream_score
                                    {
                                        best_stream_audio_ms = covered_ms;
                                        best_stream_score = score;
                                        best_stream_text = result.text;
                                        send_partial_update(
                                            &updates_tx,
                                            &mut last_sent_partial,
                                            best_stream_text.clone(),
                                        );
                                    }
                                }
                                Ok(Ok(_)) => {}
                                Ok(Err(e)) => warn!("local snapshot awaited join error: {:#}", e),
                                Err(e) => warn!("local snapshot task awaited join error: {}", e),
                            }
                        }
                        Err(_) => {
                            handle.abort();
                            debug!(
                                "local: timed out waiting full in-flight snapshot after release, will fallback"
                            );
                        }
                    }
                } else {
                    debug!(
                        "local: aborting in-flight partial snapshot (inflight_audio_ms={}, final_audio_ms={})",
                        inflight_audio_ms, final_audio_ms
                    );
                    handle.abort();
                }
            } else {
                let final_audio_ms = (pcm_bytes.len() / bytes_per_ms) as u64;
                let inflight_audio_ms = inflight_snapshot_audio_ms.unwrap_or(final_audio_ms);
                let wait_ms = Self::release_wait_timeout_ms(inflight_audio_ms).max(2_200);
                debug!(
                    "local: waiting in-flight first snapshot after release (wait_ms={}, inflight_audio_ms={}, final_audio_ms={})",
                    wait_ms, inflight_audio_ms, final_audio_ms
                );
                let mut handle = handle;
                match timeout(Duration::from_millis(wait_ms), &mut handle).await {
                    Ok(joined) => {
                        if let Some(started) = snapshot_started_at.take() {
                            last_snapshot_latency_ms = Some(started.elapsed().as_millis() as u64);
                        }
                        match joined {
                            Ok(Ok(result)) if !result.text.trim().is_empty() => {
                                Self::update_detected_lang(auto_mode, &mut detected_lang, &result);
                                let score = Self::text_score(&result.text);
                                let covered_ms = inflight_snapshot_audio_ms.unwrap_or(0);
                                if covered_ms >= best_stream_audio_ms || score >= best_stream_score
                                {
                                    best_stream_audio_ms = covered_ms;
                                    best_stream_score = score;
                                    best_stream_text = result.text;
                                    send_partial_update(
                                        &updates_tx,
                                        &mut last_sent_partial,
                                        best_stream_text.clone(),
                                    );
                                }
                            }
                            Ok(Ok(_)) => {}
                            Ok(Err(e)) => warn!("local snapshot awaited-first join error: {:#}", e),
                            Err(e) => warn!("local snapshot task awaited-first join error: {}", e),
                        }
                    }
                    Err(_) => {
                        handle.abort();
                        debug!("local: timed out waiting first in-flight snapshot after release");
                    }
                }
            }
        }

        let final_audio_ms = (pcm_bytes.len() / bytes_per_ms) as u64;
        debug!(
            "local streaming done: final_audio_ms={}, best_audio_ms={}, last_snapshot_latency_ms={:?}, best_score={}",
            final_audio_ms, best_stream_audio_ms, last_snapshot_latency_ms, best_stream_score
        );

        if !Self::should_force_full_pass(final_audio_ms, best_stream_audio_ms, &best_stream_text) {
            debug!(
                "local: returning stream result without full pass (chars={}, best_audio_ms={}, final_audio_ms={})",
                best_stream_text.chars().count(),
                best_stream_audio_ms,
                final_audio_ms
            );
            send_final_update(
                &updates_tx,
                &mut last_sent_partial,
                best_stream_text.clone(),
            );
            return Ok(best_stream_text);
        }

        debug!(
            "local: starting full pass fallback (audio_ms={}, bytes={})",
            final_audio_ms,
            pcm_bytes.len()
        );
        let full_start = Instant::now();
        let final_text = self
            .transcribe_pcm_wav_result_with_lang(sample_rate, pcm_bytes, detected_lang.as_deref())
            .await?;
        debug!(
            "local: full pass finished in {} ms, chars={}",
            full_start.elapsed().as_millis(),
            final_text.text.chars().count()
        );
        send_final_update(&updates_tx, &mut last_sent_partial, final_text.text.clone());
        Ok(final_text.text)
    }
}

pub struct AwsProvider {
    cfg: AwsConfig,
}

impl AwsProvider {
    pub fn new(cfg: AwsConfig) -> Self {
        Self { cfg }
    }
}

#[async_trait]
impl TranscribeProvider for AwsProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Aws
    }

    async fn stream_audio(
        &self,
        mut audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
        updates_tx: mpsc::UnboundedSender<TranscriptionEvent>,
    ) -> Result<String> {
        let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .load()
            .await;

        let region = sdk_config
            .region()
            .map(|r| r.as_ref().to_string())
            .ok_or_else(|| anyhow!(
                "AWS region is not resolved. Set AWS_REGION/AWS_DEFAULT_REGION or configure region in the selected AWS profile."
            ))?;

        info!(
            "Starting AWS Transcribe streaming via HTTP/2 ({} Hz), region={}, encoding={:?}...",
            sample_rate, region, self.cfg.media_encoding
        );

        let client = aws_sdk_transcribestreaming::Client::new(&sdk_config);
        let (event_tx, event_rx) =
            mpsc::channel::<std::result::Result<AwsAudioStream, AudioStreamError>>(256);

        let media_encoding_for_feed = self.cfg.media_encoding;
        let is_streaming_for_feed = is_streaming.clone();
        let feed_task = tokio::spawn(async move {
            match media_encoding_for_feed {
                AwsMediaEncoding::Pcm => {
                    // Pre-fill: send 600 ms of silence so AWS initialises its
                    // language model before real speech arrives.  This prevents
                    // the first word from being clipped or garbled due to the
                    // TLS/HTTP-2 setup latency (~300-500 ms).
                    let silence_samples = (sample_rate as usize * 600 / 1000) * 2; // 16-bit mono
                    let silence = vec![0u8; silence_samples];
                    let silence_event = AwsAudioEvent::builder()
                        .audio_chunk(Blob::new(silence))
                        .build();
                    if event_tx
                        .send(Ok(AwsAudioStream::AudioEvent(silence_event)))
                        .await
                        .is_err()
                    {
                        return;
                    }
                    debug!("aws pcm feeder: sent 600 ms silence pre-fill");

                    while let Some(chunk) = audio_rx.recv().await {
                        if chunk.is_empty() {
                            continue;
                        }
                        let audio_event = AwsAudioEvent::builder()
                            .audio_chunk(Blob::new(chunk))
                            .build();
                        if event_tx
                            .send(Ok(AwsAudioStream::AudioEvent(audio_event)))
                            .await
                            .is_err()
                        {
                            break;
                        }
                        if !is_streaming_for_feed.load(Ordering::SeqCst) {
                            debug!("aws pcm feeder observed is_streaming=false, breaking");
                            break;
                        }
                    }
                }
                AwsMediaEncoding::OggOpus => {
                    let mut ffmpeg = match tokio::process::Command::new("ffmpeg")
                        .args([
                            "-f",
                            "s16le",
                            "-ar",
                            &sample_rate.to_string(),
                            "-ac",
                            "1",
                            "-i",
                            "pipe:0",
                            "-c:a",
                            "libopus",
                            "-ar",
                            "48000",
                            "-b:a",
                            "24k",
                            "-f",
                            "ogg",
                            "pipe:1",
                        ])
                        .stdin(Stdio::piped())
                        .stdout(Stdio::piped())
                        .stderr(Stdio::null())
                        .spawn()
                    {
                        Ok(p) => p,
                        Err(e) => {
                            error!("aws ffmpeg spawn failed: {}", e);
                            return;
                        }
                    };

                    let mut stdin = ffmpeg.stdin.take().unwrap();
                    let mut stdout = ffmpeg.stdout.take().unwrap();
                    let is_streaming_writer = is_streaming_for_feed.clone();
                    let writer = tokio::spawn(async move {
                        while let Some(chunk) = audio_rx.recv().await {
                            if stdin.write_all(&chunk).await.is_err() {
                                break;
                            }
                            if !is_streaming_writer.load(Ordering::SeqCst) {
                                debug!("aws opus writer observed is_streaming=false, breaking");
                                break;
                            }
                        }
                        drop(stdin);
                    });

                    let mut buffer = vec![0u8; 4096];
                    loop {
                        match stdout.read(&mut buffer).await {
                            Ok(0) => break,
                            Ok(n) => {
                                let audio_event = AwsAudioEvent::builder()
                                    .audio_chunk(Blob::new(buffer[..n].to_vec()))
                                    .build();
                                if event_tx
                                    .send(Ok(AwsAudioStream::AudioEvent(audio_event)))
                                    .await
                                    .is_err()
                                {
                                    break;
                                }
                            }
                            Err(e) => {
                                error!("aws ffmpeg stdout read error: {}", e);
                                break;
                            }
                        }
                    }
                    let _ = writer.await;
                    let _ = ffmpeg.wait().await;
                }
            }
        });

        let outbound = ReceiverStream::new(event_rx);
        let audio_stream = EventStreamSender::from(outbound);

        let media_encoding = match self.cfg.media_encoding {
            AwsMediaEncoding::Pcm => MediaEncoding::Pcm,
            AwsMediaEncoding::OggOpus => MediaEncoding::OggOpus,
        };
        let aws_sample_rate_hz = match self.cfg.media_encoding {
            AwsMediaEncoding::Pcm => sample_rate as i32,
            // Ogg Opus stream is encoded to 48k for AWS compatibility.
            AwsMediaEncoding::OggOpus => 48_000,
        };

        let mut request = client
            .start_stream_transcription()
            .media_encoding(media_encoding)
            .media_sample_rate_hertz(aws_sample_rate_hz)
            .audio_stream(audio_stream);

        if self.cfg.identify_language {
            if self.cfg.language_options.is_empty() {
                return Err(anyhow!(
                    "S2T_AWS_IDENTIFY_LANGUAGE is enabled but S2T_AWS_LANGUAGE_OPTIONS is empty"
                ));
            }
            for raw_code in &self.cfg.language_options {
                LanguageCode::try_parse(raw_code).map_err(|_| {
                    anyhow!(
                        "Unsupported code '{}' in S2T_AWS_LANGUAGE_OPTIONS",
                        raw_code
                    )
                })?;
            }
            let options_csv = self.cfg.language_options.join(",");
            request = request.language_options(options_csv);
            match self.cfg.identify_mode {
                AwsIdentifyMode::Single => {
                    request = request.identify_language(true);
                    if let Some(raw_preferred) = &self.cfg.preferred_language {
                        let preferred = LanguageCode::try_parse(raw_preferred).map_err(|_| {
                            anyhow!("Unsupported S2T_AWS_PREFERRED_LANGUAGE='{}'", raw_preferred)
                        })?;
                        request = request.preferred_language(preferred);
                    }
                }
                AwsIdentifyMode::Multiple => {
                    request = request.identify_multiple_languages(true);
                }
            }
            info!(
                "AWS language mode: auto-detect ({:?}), options={:?}, preferred={:?}",
                self.cfg.identify_mode, self.cfg.language_options, self.cfg.preferred_language
            );
        } else {
            let language_code = LanguageCode::try_parse(&self.cfg.language_code).map_err(|_| {
                anyhow!(
                    "Unsupported S2T_AWS_LANGUAGE_CODE='{}'. See AWS LanguageCode values.",
                    self.cfg.language_code
                )
            })?;
            request = request.language_code(language_code);
            info!("AWS language mode: fixed '{}'", self.cfg.language_code);
        }

        let mut output = request
            .send()
            .await
            .context("AWS start_stream_transcription failed")?;

        let mut final_transcript = String::new();
        let mut last_sent_partial = String::new();

        while let Some(event) = output
            .transcript_result_stream
            .recv()
            .await
            .context("AWS transcript stream receive failed")?
        {
            match event {
                TranscriptResultStream::TranscriptEvent(transcript_event) => {
                    if let Some(transcript) = transcript_event.transcript {
                        if let Some(results) = transcript.results {
                            for result in results {
                                if let Some(alternatives) = result.alternatives {
                                    if let Some(alt) = alternatives.first() {
                                        if let Some(text) = &alt.transcript {
                                            if text.trim().is_empty() {
                                                continue;
                                            }
                                            if result.is_partial {
                                                send_partial_update(
                                                    &updates_tx,
                                                    &mut last_sent_partial,
                                                    join_transcript_parts(&final_transcript, text),
                                                );
                                            } else {
                                                debug!("AWS final chunk: {}", text);
                                                final_transcript.push_str(text.trim());
                                                final_transcript.push(' ');
                                                send_partial_update(
                                                    &updates_tx,
                                                    &mut last_sent_partial,
                                                    final_transcript.trim().to_string(),
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {
                    warn!("AWS transcript stream received unhandled event variant");
                }
            }
        }

        if let Err(e) = feed_task.await {
            warn!("aws feeder task join error: {}", e);
        }
        let final_text = final_transcript.trim().to_string();
        send_final_update(&updates_tx, &mut last_sent_partial, final_text.clone());
        Ok(final_text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};
    use tokio::sync::mpsc;

    #[test]
    fn provider_kind_parse_ok() {
        assert_eq!(ProviderKind::parse("google").unwrap(), ProviderKind::Google);
        assert_eq!(
            ProviderKind::parse("google-v2").unwrap(),
            ProviderKind::Google
        );
        assert_eq!(ProviderKind::parse("local").unwrap(), ProviderKind::Local);
        assert_eq!(ProviderKind::parse("aws").unwrap(), ProviderKind::Aws);
    }

    #[test]
    fn provider_kind_parse_unknown() {
        let err = ProviderKind::parse("wat").unwrap_err();
        assert!(err.to_string().contains("Unsupported S2T_ASR_PROVIDER"));
    }

    #[test]
    fn extract_whisper_stream_text_filters_system_lines() {
        let sample = r#"
ggml_cuda_init: found 1 CUDA devices:
main: processing 12800 samples
[Start speaking]
  Привет это проверка стрима
whisper_print_timings: total time = 1234 ms
"#;
        let text = LocalProvider::extract_whisper_stream_text(sample);
        assert_eq!(text, "Привет это проверка стрима");
    }

    #[test]
    fn extract_whisper_stream_text_ignores_tensor_core_warning() {
        let sample = r#"
The following devices will have suboptimal performance due to a lack of tensor cores:
Consider compiling with CMAKE_CUDA_ARCHITECTURES=61-virtual;80-virtual and DGGML_CUDA_FORCE_MMQ
  тестовая фраза для распознавания
"#;
        let text = LocalProvider::extract_whisper_stream_text(sample);
        assert_eq!(text, "тестовая фраза для распознавания");
    }

    #[tokio::test]
    async fn local_true_stream_flush_and_parse_smoke() {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let dir = PathBuf::from(format!("/tmp/s2t_true_stream_test_{ts}"));
        fs::create_dir_all(&dir).expect("create temp dir");

        let fake_model = dir.join("fake-model.bin");
        fs::write(&fake_model, b"fake").expect("write fake model");

        let fake_stream = dir.join("fake-whisper-stream.sh");
        let script = r#"#!/usr/bin/env bash
set -euo pipefail
echo "The following devices will have suboptimal performance due to a lack of tensor cores:" >&2
sleep 1
echo "  тестовая фраза для распознавания" >&2
while true; do sleep 1; done
"#;
        fs::write(&fake_stream, script).expect("write fake stream script");
        let mut perms = fs::metadata(&fake_stream).expect("stat").permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&fake_stream, perms).expect("chmod");

        let provider = LocalProvider::new(LocalConfig {
            whisper_server_url: "http://127.0.0.1:9788/inference".to_string(),
            request_language: Some("ru".to_string()),
            streaming_enabled: true,
            stream_bin: fake_stream.display().to_string(),
            model_path: fake_model.display().to_string(),
            threads: 1,
            stream_step_ms: 800,
            stream_length_ms: 2400,
            stream_keep_ms: 200,
            stream_flush_after_release_ms: 2200,
            stream_capture_id: None,
            stream_keep_context: true,
        });

        let is_streaming = Arc::new(AtomicBool::new(true));
        let flag = is_streaming.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(1200)).await;
            flag.store(false, Ordering::SeqCst);
        });

        let text = provider
            .transcribe_true_stream(
                is_streaming,
                &mpsc::unbounded_channel::<TranscriptionEvent>().0,
            )
            .await
            .expect("true stream must return text");
        assert_eq!(text, "тестовая фраза для распознавания");
    }

    #[test]
    fn aws_media_encoding_parse_ok() {
        assert_eq!(
            AwsMediaEncoding::parse("pcm").unwrap(),
            AwsMediaEncoding::Pcm
        );
        assert_eq!(
            AwsMediaEncoding::parse("ogg-opus").unwrap(),
            AwsMediaEncoding::OggOpus
        );
        assert_eq!(
            AwsMediaEncoding::parse("opus").unwrap(),
            AwsMediaEncoding::OggOpus
        );
    }

    #[test]
    fn local_auto_language_is_not_sent_as_literal_auto() {
        assert_eq!(
            LocalProvider::normalize_request_language_param(Some("auto")),
            None
        );
        assert_eq!(
            LocalProvider::normalize_request_language_param(Some("AUTO")),
            None
        );
        assert_eq!(
            LocalProvider::normalize_request_language_param(Some("ru-RU")),
            Some("ru".to_string())
        );
    }

    #[test]
    fn local_short_complete_snapshot_does_not_force_full_pass() {
        assert!(!LocalProvider::should_force_full_pass(
            2_400,
            2_300,
            "Привет мир."
        ));
        assert!(!LocalProvider::should_force_full_pass(
            3_200,
            2_600,
            "Hello there!"
        ));
    }

    #[test]
    fn local_force_full_pass_when_snapshot_is_obviously_truncated() {
        assert!(LocalProvider::should_force_full_pass(
            6_000,
            2_000,
            "незаконченная фраза"
        ));
        assert!(LocalProvider::should_force_full_pass(10_000, 5_000, "hi"));
    }

    #[test]
    fn runtime_config_respects_local_streaming_flag() {
        unsafe {
            std::env::set_var("S2T_ASR_PROVIDER", "local");
            std::env::set_var("S2T_LOCAL_STREAMING", "0");
        }
        let cfg = RuntimeConfig::from_env().expect("runtime config");
        assert!(!cfg.local.streaming_enabled);
        unsafe {
            std::env::remove_var("S2T_LOCAL_STREAMING");
            std::env::remove_var("S2T_ASR_PROVIDER");
        }
    }

    #[tokio::test]
    #[ignore = "manual smoke: requires AWS creds + env S2T_AWS_SMOKE_WAV"]
    async fn aws_smoke_transcribe_fixture() {
        let wav_path = std::env::var("S2T_AWS_SMOKE_WAV")
            .expect("S2T_AWS_SMOKE_WAV must point to a WAV file with speech");

        let mut reader = hound::WavReader::open(&wav_path).expect("open wav");
        let spec = reader.spec();
        let sample_rate = spec.sample_rate;
        assert!(
            spec.channels == 1 || spec.channels == 2,
            "expected mono/stereo wav fixture, got channels={}",
            spec.channels
        );
        assert_eq!(spec.bits_per_sample, 16, "expected 16-bit wav fixture");

        let provider = AwsProvider::new(AwsConfig {
            language_code: "ru-RU".to_string(),
            identify_language: false,
            identify_mode: AwsIdentifyMode::Multiple,
            language_options: vec!["ru-RU".to_string(), "en-US".to_string()],
            preferred_language: Some("ru-RU".to_string()),
            media_encoding: AwsMediaEncoding::OggOpus,
        });

        let (tx, rx) = mpsc::channel::<Vec<u8>>(128);
        let is_streaming = Arc::new(AtomicBool::new(true));
        let is_streaming_writer = is_streaming.clone();

        let raw_samples: Vec<i16> = reader
            .samples::<i16>()
            .collect::<std::result::Result<Vec<_>, _>>()
            .expect("read samples");
        let samples: Vec<i16> = if spec.channels == 2 {
            raw_samples
                .chunks_exact(2)
                .map(|lr| {
                    let l = lr[0] as i32;
                    let r = lr[1] as i32;
                    ((l + r) / 2) as i16
                })
                .collect()
        } else {
            raw_samples
        };

        tokio::spawn(async move {
            let mut chunk = Vec::with_capacity(3200);
            for s in samples {
                chunk.extend_from_slice(&s.to_le_bytes());
                if chunk.len() >= 3200 {
                    if tx.send(chunk.clone()).await.is_err() {
                        return;
                    }
                    chunk.clear();
                }
            }
            if !chunk.is_empty() {
                let _ = tx.send(chunk).await;
            }
            is_streaming_writer.store(false, Ordering::SeqCst);
        });

        let text = provider
            .stream_audio(
                rx,
                sample_rate,
                is_streaming,
                mpsc::unbounded_channel::<TranscriptionEvent>().0,
            )
            .await
            .expect("aws stream must succeed");

        assert!(
            !text.trim().is_empty(),
            "aws returned empty transcript for fixture {wav_path}"
        );
        println!("AWS smoke transcript: {}", text);
    }
}
