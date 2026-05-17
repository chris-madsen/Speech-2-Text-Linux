use anyhow::{Result, Context};
use log::{info, debug, error};
use tonic::{transport::Channel, Request};
use tokio::sync::mpsc;
use std::process::{Command, Stdio};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
    StreamingRecognizeRequest,
    StreamingRecognitionConfig,
    RecognitionConfig,
    ExplicitDecodingConfig,
    RecognitionFeatures,
    StreamingRecognitionFeatures,
};

pub struct GoogleCloudClient {
    project_id: String,
    location: String,
    recognizer_id: String,
}

impl GoogleCloudClient {
    pub fn new(project_id: String, location: String, recognizer_id: String) -> Self {
        Self {
            project_id,
            location,
            recognizer_id,
        }
    }

    fn get_access_token(&self) -> Result<String> {
        let output = std::process::Command::new("gcloud")
            .args(["auth", "print-access-token"])
            .output()
            .context("Failed to execute gcloud auth")?;
        
        if !output.status.success() {
            return Err(anyhow::anyhow!("gcloud auth failed: {}", String::from_utf8_lossy(&output.stderr)));
        }

        Ok(String::from_utf8(output.stdout)?.trim().to_string())
    }

    pub async fn stream_audio(&self, mut audio_rx: mpsc::Receiver<Vec<u8>>, sample_rate: u32, is_streaming: std::sync::Arc<std::sync::atomic::AtomicBool>) -> Result<String> {
        let token = self.get_access_token()?;
        info!("Starting gRPC streaming to Google Cloud via Envoy ({} Hz, Opus)...", sample_rate);

        let channel = Channel::from_static("http://127.0.0.1:50051")
            .connect()
            .await?;

        let mut client = SpeechClient::with_interceptor(channel, move |mut req: tonic::Request<()>| {
            req.metadata_mut().insert("authorization", format!("Bearer {}", token).parse().unwrap());
            req.metadata_mut().insert("x-goog-user-project", self.project_id.parse().unwrap());
            Ok(req)
        });

        let recognizer = format!("projects/{}/locations/{}/recognizers/{}", 
            self.project_id, self.location, self.recognizer_id);

        // Spawn ffmpeg for Opus encoding
        let mut ffmpeg = tokio::process::Command::new("ffmpeg")
            .args([
                "-f", "s16le",
                "-ar", &sample_rate.to_string(),
                "-ac", "1",
                "-i", "pipe:0",
                "-c:a", "libopus",
                "-b:a", "24k",
                "-f", "ogg",
                "pipe:1",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("Failed to spawn ffmpeg")?;

        let mut stdin = ffmpeg.stdin.take().unwrap();
        let mut stdout = ffmpeg.stdout.take().unwrap();

        // Task to feed raw audio to ffmpeg
        tokio::spawn(async move {
            while let Some(chunk) = audio_rx.recv().await {
                if stdin.write_all(&chunk).await.is_err() {
                    debug!("ffmpeg stdin write error, breaking");
                    break;
                }
                if !is_streaming.load(std::sync::atomic::Ordering::SeqCst) {
                    debug!("is_streaming is false, breaking");
                    break;
                }
            }
            debug!("audio_rx closed or loop broken, dropping stdin");
            drop(stdin);
        });

        let outbound = async_stream::stream! {
            // 1. Send Config
            yield StreamingRecognizeRequest {
                recognizer: recognizer.clone(),
                streaming_request: Some(StreamingRequest::StreamingConfig(
                    StreamingRecognitionConfig {
                        config: Some(RecognitionConfig {
                            decoding_config: Some(google::cloud::speech::v2::recognition_config::DecodingConfig::ExplicitDecodingConfig(ExplicitDecodingConfig {
                                encoding: 6, // OggOpus
                                sample_rate_hertz: sample_rate as i32,
                                audio_channel_count: 1,
                            })),
                            language_codes: vec!["ru-RU".to_string()],
                            model: "chirp_2".to_string(),
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

            // 2. Stream Opus Chunks from ffmpeg stdout
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
                        debug!("Final result received after {:?}: {}", start_wait.elapsed(), alt.transcript);
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
