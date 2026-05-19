use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use aws_sdk_transcribestreaming::primitives::event_stream::EventStreamSender;
use aws_sdk_transcribestreaming::types::error::AudioStreamError;
use aws_sdk_transcribestreaming::types::{
    AudioEvent as AwsAudioEvent,
    AudioStream as AwsAudioStream,
    LanguageCode,
    MediaEncoding,
    TranscriptResultStream,
};
use aws_smithy_types::Blob;
use log::{debug, info, warn, error};
use serde_json::Value;
use std::env;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
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
    speech_client::SpeechClient,
    streaming_recognize_request::StreamingRequest,
    ExplicitDecodingConfig,
    RecognitionConfig,
    RecognitionFeatures,
    StreamingRecognitionConfig,
    StreamingRecognitionFeatures,
    StreamingRecognizeRequest,
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
            other => Err(anyhow!("Unsupported S2T_ASR_PROVIDER='{other}' (expected google|local|aws)")),
        }
    }
}

#[async_trait]
pub trait TranscribeProvider: Send + Sync {
    fn kind(&self) -> ProviderKind;

    async fn stream_audio(
        &self,
        audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
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
}

#[derive(Debug, Clone)]
pub struct AwsConfig {
    pub language_code: String,
    pub media_encoding: AwsMediaEncoding,
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
        let google_project = env_var("S2T_GCP_PROJECT")
            .or_else(|| env_var("GOOGLE_CLOUD_PROJECT"))
            .unwrap_or_else(|| {
                warn!(
                    "S2T_GCP_PROJECT/GOOGLE_CLOUD_PROJECT are not set, using backward-compatible default '{}'.",
                    google_project_default
                );
                google_project_default
            });

        let google_language = env_var("S2T_GOOGLE_LANGUAGE_CODE").unwrap_or_else(|| "ru-RU".to_string());
        let google = GoogleConfig {
            project_id: google_project,
            location: env_var("S2T_GOOGLE_V2_LOCATION").unwrap_or_else(|| "europe-west4".to_string()),
            recognizer_id: env_var("S2T_GOOGLE_V2_RECOGNIZER").unwrap_or_else(|| "_".to_string()),
            language_code: google_language.clone(),
            model: env_var("S2T_GOOGLE_V2_MODEL").unwrap_or_else(|| "chirp_2".to_string()),
            envoy_endpoint: env_var("S2T_GOOGLE_ENVOY_ENDPOINT").unwrap_or_else(|| "http://127.0.0.1:50051".to_string()),
        };

        let local = LocalConfig {
            whisper_server_url: env_var("S2T_WHISPER_SERVER_URL")
                .unwrap_or_else(|| "http://127.0.0.1:9788/inference".to_string()),
        };

        let aws = AwsConfig {
            language_code: env_var("S2T_AWS_LANGUAGE_CODE")
                .or_else(|| env_var("S2T_GOOGLE_LANGUAGE_CODE"))
                .unwrap_or_else(|| "ru-RU".to_string()),
            media_encoding: AwsMediaEncoding::parse(
                &env_var("S2T_AWS_MEDIA_ENCODING").unwrap_or_else(|| "pcm".to_string()),
            )?,
        };

        Ok(Self {
            provider,
            google,
            local,
            aws,
        })
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
        let mut client = SpeechClient::with_interceptor(channel, move |mut req: tonic::Request<()>| {
            req.metadata_mut()
                .insert("authorization", format!("Bearer {}", token).parse().unwrap());
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
                    } else {
                        debug!("Interim result after {:?}: {}", start_wait.elapsed(), alt.transcript);
                    }
                }
            }
        }
        info!("Google Cloud stream closed after {:?}", start_wait.elapsed());

        Ok(final_transcript.trim().to_string())
    }
}

pub struct LocalProvider {
    cfg: LocalConfig,
    http: reqwest::Client,
}

impl LocalProvider {
    pub fn new(cfg: LocalConfig) -> Self {
        Self {
            cfg,
            http: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl TranscribeProvider for LocalProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Local
    }

    async fn stream_audio(
        &self,
        mut audio_rx: mpsc::Receiver<Vec<u8>>,
        sample_rate: u32,
        is_streaming: Arc<AtomicBool>,
    ) -> Result<String> {
        info!(
            "Starting local whisper-server transcription ({} Hz, PCM->WAV)...",
            sample_rate
        );

        let mut pcm_bytes = Vec::new();
        while let Some(chunk) = audio_rx.recv().await {
            pcm_bytes.extend_from_slice(&chunk);
            if !is_streaming.load(Ordering::SeqCst) {
                break;
            }
        }

        if pcm_bytes.is_empty() {
            return Ok(String::new());
        }

        let mut cursor = std::io::Cursor::new(Vec::new());
        {
            let spec = hound::WavSpec {
                channels: 1,
                sample_rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            let mut writer = hound::WavWriter::new(&mut cursor, spec)
                .context("failed to create WAV encoder")?;

            for sample in pcm_bytes.chunks_exact(2) {
                let s = i16::from_le_bytes([sample[0], sample[1]]);
                writer
                    .write_sample(s)
                    .context("failed to write WAV sample")?;
            }
            writer.finalize().context("failed to finalize WAV")?;
        }

        let wav_bytes = cursor.into_inner();
        let part = reqwest::multipart::Part::bytes(wav_bytes)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;
        let form = reqwest::multipart::Form::new().part("file", part);

        let response = self
            .http
            .post(&self.cfg.whisper_server_url)
            .multipart(form)
            .send()
            .await
            .context("local whisper-server request failed")?;

        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(anyhow!(
                "local whisper-server returned {}: {}",
                status,
                body
            ));
        }

        let parsed: Value = serde_json::from_str(&body)
            .context("failed to parse whisper-server JSON response")?;
        let text = parsed
            .get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();

        Ok(text)
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

        info!("Starting AWS Transcribe streaming via HTTP/2 ({} Hz), region={}, encoding={:?}...", sample_rate, region, self.cfg.media_encoding);

        let client = aws_sdk_transcribestreaming::Client::new(&sdk_config);
        let language_code = LanguageCode::try_parse(&self.cfg.language_code)
            .map_err(|_| anyhow!(
                "Unsupported S2T_AWS_LANGUAGE_CODE='{}'. See AWS LanguageCode values.",
                self.cfg.language_code
            ))?;
        let (event_tx, event_rx) = mpsc::channel::<std::result::Result<AwsAudioStream, AudioStreamError>>(256);

        let media_encoding_for_feed = self.cfg.media_encoding;
        let is_streaming_for_feed = is_streaming.clone();
        let feed_task = tokio::spawn(async move {
            match media_encoding_for_feed {
                AwsMediaEncoding::Pcm => {
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
                            debug!("aws pcm feeder observed is_streaming=false");
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
                                debug!("aws opus writer observed is_streaming=false");
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

        let mut output = client
            .start_stream_transcription()
            .language_code(language_code)
            .media_encoding(media_encoding)
            .media_sample_rate_hertz(aws_sample_rate_hz)
            .audio_stream(audio_stream)
            .send()
            .await
            .context("AWS start_stream_transcription failed")?;

        let mut final_transcript = String::new();

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
                                if result.is_partial {
                                    continue;
                                }
                                if let Some(alternatives) = result.alternatives {
                                    if let Some(alt) = alternatives.first() {
                                        if let Some(text) = &alt.transcript {
                                            if !text.trim().is_empty() {
                                                debug!("AWS final chunk: {}", text);
                                                final_transcript.push_str(text.trim());
                                                final_transcript.push(' ');
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

        Ok(final_transcript.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    #[test]
    fn provider_kind_parse_ok() {
        assert_eq!(ProviderKind::parse("google").unwrap(), ProviderKind::Google);
        assert_eq!(ProviderKind::parse("google-v2").unwrap(), ProviderKind::Google);
        assert_eq!(ProviderKind::parse("local").unwrap(), ProviderKind::Local);
        assert_eq!(ProviderKind::parse("aws").unwrap(), ProviderKind::Aws);
    }

    #[test]
    fn provider_kind_parse_unknown() {
        let err = ProviderKind::parse("wat").unwrap_err();
        assert!(err.to_string().contains("Unsupported S2T_ASR_PROVIDER"));
    }

    #[test]
    fn aws_media_encoding_parse_ok() {
        assert_eq!(AwsMediaEncoding::parse("pcm").unwrap(), AwsMediaEncoding::Pcm);
        assert_eq!(
            AwsMediaEncoding::parse("ogg-opus").unwrap(),
            AwsMediaEncoding::OggOpus
        );
        assert_eq!(
            AwsMediaEncoding::parse("opus").unwrap(),
            AwsMediaEncoding::OggOpus
        );
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
            .stream_audio(rx, sample_rate, is_streaming)
            .await
            .expect("aws stream must succeed");

        assert!(
            !text.trim().is_empty(),
            "aws returned empty transcript for fixture {wav_path}"
        );
        println!("AWS smoke transcript: {}", text);
    }
}
