#!/usr/bin/env bash
set -euo pipefail

# Required inputs.
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required}"
REGION="${REGION:-europe-west4}"
SERVICE_NAME="${SERVICE_NAME:-whisper-l4}"
REPOSITORY="${REPOSITORY:-whisper}"
IMAGE_NAME="${IMAGE_NAME:-whisper-l4}"
PLATFORM="${PLATFORM:-managed}"

# Runtime config.
CPU="${CPU:-8}"
MEMORY="${MEMORY:-32Gi}"
GPU="${GPU:-1}"
GPU_TYPE="${GPU_TYPE:-nvidia-l4}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-1}"
TIMEOUT="${TIMEOUT:-900}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-7200s}"
CONCURRENCY="${CONCURRENCY:-1}"
ALLOW_UNAUTH="${ALLOW_UNAUTH:-true}"
WHISPER_USE_FA="${WHISPER_USE_FA:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

gcloud config set project "${PROJECT_ID}" >/dev/null

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com >/dev/null

if ! gcloud artifacts repositories describe "${REPOSITORY}" --location "${REGION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPOSITORY}" \
    --repository-format docker \
    --location "${REGION}" \
    --description "Whisper GPU images" >/dev/null
fi

gcloud builds submit "${ROOT_DIR}" --tag "${IMAGE_URI}" --timeout "${BUILD_TIMEOUT}"

DEPLOY_ARGS=(
  "${SERVICE_NAME}"
  --platform "${PLATFORM}"
  --region "${REGION}"
  --execution-environment gen2
  --image "${IMAGE_URI}"
  --cpu "${CPU}"
  --memory "${MEMORY}"
  --gpu "${GPU}"
  --gpu-type "${GPU_TYPE}"
  --no-gpu-zonal-redundancy
  --min-instances "${MIN_INSTANCES}"
  --max-instances "${MAX_INSTANCES}"
  --timeout "${TIMEOUT}"
  --concurrency "${CONCURRENCY}"
  --no-cpu-throttling
  --set-env-vars "WHISPER_THREADS=${CPU},WHISPER_USE_FA=${WHISPER_USE_FA}"
)

if [ "${ALLOW_UNAUTH}" = "true" ]; then
  DEPLOY_ARGS+=(--allow-unauthenticated)
else
  DEPLOY_ARGS+=(--no-allow-unauthenticated)
fi

gcloud run deploy "${DEPLOY_ARGS[@]}"

echo "Cloud Run service URL:"
SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" --platform "${PLATFORM}" --region "${REGION}" --format='value(status.url)')"
echo "${SERVICE_URL}"
echo
echo "S2T user env overrides:"
echo "S2T_ASR_PROVIDER=gcp-l4"
echo "S2T_GCP_WHISPER_URL=${SERVICE_URL}"
echo "S2T_GCP_WHISPER_INFER_PATH=/inference"
echo "S2T_GCP_WHISPER_TIMEOUT_SEC=5"
echo "S2T_GCP_WHISPER_CONNECT_TIMEOUT_SEC=3"
