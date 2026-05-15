# Whisper Large-v3-Turbo on GCP Cloud Run (L4)

This module adds a **cloud option** for running Whisper Large-v3-Turbo on GCP without changing existing local flows.

## Architecture

- Container base: `cachyos/cachyos:latest`
- Runtime: CUDA-capable whisper.cpp build (`GGML_CUDA=ON`)
- API: FastAPI (`/health`, `/infer`, `/inference`)
- Cloud target: Cloud Run with `1 x NVIDIA L4`, `8 vCPU`, `32Gi RAM`, `min-instances=0`
- Local hot keep-alive: systemd daemon that pings `/health` every 8 minutes

## Files

- `Dockerfile`: CachyOS + whisper.cpp + CUDA image
- `api/main.py`: stateless inference API (`/inference` is compatible with S2T controller)
- `deploy_cloud_run.sh`: build and deploy to Cloud Run
- `keepalive/*`: local daemon + systemd unit

## Deploy

```bash
cd whisper-l4
export PROJECT_ID="your-gcp-project-id"
export REGION="europe-north1"
./deploy_cloud_run.sh
```

After deploy:

```bash
curl -fsS "$(gcloud run services describe whisper-l4 --region europe-north1 --format='value(status.url)')/health"
```

## Inference Example

```bash
SERVICE_URL="https://YOUR_SERVICE_URL"
curl -fsS -X POST "${SERVICE_URL}/inference" \
  -F "audio=@/path/to/audio.wav" \
  -F "language=ru" \
  -F "translate=false" \
  -F "threads=8"
```

## S2T Integration

Add these values into `~/.config/s2t/s2t.env` for the target user:

```bash
S2T_ASR_PROVIDER=gcp-l4
S2T_GCP_WHISPER_URL=https://YOUR_SERVICE_URL
S2T_GCP_WHISPER_INFER_PATH=/inference
S2T_GCP_WHISPER_TIMEOUT_SEC=5
S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC=3
S2T_NETWORK_ONLY=0
```

`S2T_NETWORK_ONLY=0` keeps local whisper as fallback.

## Keep-Alive Daemon (Local)

Install:

```bash
sudo gcp/whisper-l4/keepalive/install_keepalive.sh
sudoedit /etc/default/whisper-cloud-keepalive
sudo systemctl restart whisper-cloud-keepalive.service
```

Check logs:

```bash
journalctl -u whisper-cloud-keepalive.service -f
```

Remove:

```bash
sudo gcp/whisper-l4/keepalive/uninstall_keepalive.sh
```
